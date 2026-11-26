// Lógica de la Edge Function «pagos»: cobrar el trabajo terminado con QR del Banco Económico.
// Es lo mismo que servidor-pagos/servidor.js (probado con plata real), pero guarda los pagos en la
// tabla public.pagos_qr de Supabase en vez de un archivo, y corre en internet: el APK no depende
// de ninguna laptop. Corre en Deno (Supabase) y en Node 22+ (pruebas locales).
//
// Rutas (la URL pública es https://<proyecto>.supabase.co/functions/v1/pagos):
//   POST /pagos                 { ofertaId }  → genera el QR (solo si el trabajo está completado)
//   GET  /pagos/<id>                          → estado del cobro (la app pregunta cada 3 s)
//   GET  /pagos/oferta/<ofertaId>             → estado del pago de una oferta
//   POST /pagos/aviso-banco                   → «URL de notificación» que se registra en el banco
//   POST /pagos/revisar   (x-revision-token)  → revisión de cada minuto (pg_cron)
//   GET  /pagos/salud
import { randomBytes } from 'node:crypto';
import { BancoEconomico, ErrorBanco, fechaBolivia } from './baneco.ts';
import type { PagoBanco } from './baneco.ts';

export type Config = {
  banco: BancoEconomico | null; // null = faltan los datos del banco
  supabaseUrl: string;
  serviceKey: string; // clave de servicio (la pone Supabase sola en las Edge Functions)
  montoPrueba: number; // > 0: cada QR sale por este monto
  vidaMin: number; // minutos que vale un QR
  avisoToken: string; // token del aviso del banco (opcional)
  revisionToken: string; // token del cron de revisión
};

class ErrorHttp extends Error {
  status: number;
  constructor(status: number, mensaje: string) { super(mensaje); this.status = status; }
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-revision-token',
};
const json = (status: number, cuerpo: unknown) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...CORS } });

/** Lee la configuración de las variables de entorno (Deno.env.get en Supabase, process.env en Node). */
export function configDesdeEnv(get: (k: string) => string | undefined): Config {
  let banco: BancoEconomico | null = null;
  if (get('BANECO_USUARIO')) {
    try {
      banco = new BancoEconomico({
        url: get('BANECO_URL'),
        usuario: get('BANECO_USUARIO') || '',
        clave: get('BANECO_CLAVE') || '',
        llaveAes: get('BANECO_LLAVE_AES') || '',
        cuenta: get('BANECO_CUENTA') || '',
      });
    } catch (e) {
      console.error('Datos del banco inválidos:', (e as Error).message);
    }
  }
  // Clave de servicio: la clásica (JWT) o una de las nuevas «sb_secret_…»
  let serviceKey = get('SUPABASE_SERVICE_ROLE_KEY') || get('PAGOS_SERVICE_KEY') || '';
  if (!serviceKey && get('SUPABASE_SECRET_KEYS')) {
    try { serviceKey = String(Object.values(JSON.parse(get('SUPABASE_SECRET_KEYS') || '{}'))[0] || ''); } catch { /* sin clave */ }
  }
  const monto = get('MONTO_PRUEBA');
  return {
    banco,
    supabaseUrl: (get('SUPABASE_URL') || '').replace(/\/$/, ''),
    serviceKey,
    montoPrueba: monto === undefined || monto === '' ? 1 : Number(monto) || 0,
    vidaMin: Number(get('QR_VIDA_MINUTOS')) || 15,
    avisoToken: get('BANECO_AVISO_TOKEN') || '',
    revisionToken: get('REVISION_TOKEN') || '',
  };
}

export function crearManejador(cfg: Config) {
  const vidaMs = cfg.vidaMin * 60000;
  const sesiones = new Map<string, { usuarioId: string; hasta: number }>();
  const clavePorHeader = cfg.serviceKey.startsWith('eyJ')
    ? { apikey: cfg.serviceKey, Authorization: `Bearer ${cfg.serviceKey}` }
    : { apikey: cfg.serviceKey };

  // ── Base de datos (PostgREST con la clave de servicio) ──
  async function rest(metodo: string, ruta: string, cuerpo?: unknown, prefer?: string): Promise<any> {
    let r: Response;
    try {
      r = await fetch(`${cfg.supabaseUrl}/rest/v1/${ruta}`, {
        method: metodo,
        headers: { ...clavePorHeader, 'Content-Type': 'application/json', Accept: 'application/json', ...(prefer ? { Prefer: prefer } : {}) },
        body: cuerpo ? JSON.stringify(cuerpo) : undefined,
        signal: AbortSignal.timeout(10000),
      });
    } catch {
      throw new ErrorHttp(502, 'No se pudo hablar con la base de datos. Prueba de nuevo.');
    }
    const t = await r.text();
    let j: any = null;
    try { j = t ? JSON.parse(t) : null; } catch { /* no es JSON */ }
    if (!r.ok) {
      const e = new ErrorHttp(r.status === 409 ? 409 : 502, `Base de datos ${r.status}: ${t.slice(0, 200)}`) as ErrorHttp & { codigo?: string };
      e.codigo = j?.code;
      throw e;
    }
    return j;
  }
  const db = {
    oferta: async (id: number) =>
      ((await rest('GET', `offers?id=eq.${id}&select=id,price,status,request_id,technician_id,service_requests(client_id,category,status,work_stage)`)) || [])[0] || null,
    pagosDeOferta: async (id: number): Promise<any[]> => (await rest('GET', `pagos_qr?offer_id=eq.${id}&select=*&order=creado.asc`)) || [],
    pago: async (id: number) => ((await rest('GET', `pagos_qr?id=eq.${id}&select=*`)) || [])[0] || null,
    pagoPorQr: async (qr: string) => ((await rest('GET', `pagos_qr?qr_id=eq.${encodeURIComponent(qr)}&select=*`)) || [])[0] || null,
    crear: async (fila: Record<string, unknown>) => (await rest('POST', 'pagos_qr', fila, 'return=representation'))[0],
    // Cambia el cobro SOLO si sigue en `estadoActual`: así un pago se marca una sola vez
    cambiarSi: async (id: number, estadoActual: string, cambios: Record<string, unknown>): Promise<any[]> =>
      (await rest('PATCH', `pagos_qr?id=eq.${id}&estado=eq.${estadoActual}`, cambios, 'return=representation')) || [],
    tocar: (id: number) => rest('PATCH', `pagos_qr?id=eq.${id}`, { ultima_consulta: new Date().toISOString() }),
    pendientes: async (): Promise<any[]> => (await rest('GET', 'pagos_qr?estado=eq.pendiente&select=*&order=creado.asc&limit=200')) || [],
    vencidosDesde: async (iso: string): Promise<any[]> => (await rest('GET', `pagos_qr?estado=eq.vencido&creado=gte.${encodeURIComponent(iso)}&select=*`)) || [],
  };

  // ── Quién pide (token de sesión de Supabase) ──
  async function usuarioDe(req: Request): Promise<string> {
    const token = String(req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
    if (!token) throw new ErrorHttp(401, 'Falta iniciar sesión.');
    const s = sesiones.get(token);
    if (s && s.hasta > Date.now()) return s.usuarioId;
    let r: Response;
    try {
      r = await fetch(`${cfg.supabaseUrl}/auth/v1/user`, {
        headers: { apikey: cfg.serviceKey, Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(10000),
      });
    } catch {
      throw new ErrorHttp(502, 'No se pudo verificar tu sesión. Prueba de nuevo.');
    }
    if (!r.ok) throw new ErrorHttp(401, 'Tu sesión venció. Vuelve a iniciar sesión en la app.');
    const u = await r.json();
    if (!u?.id) throw new ErrorHttp(401, 'Tu sesión venció. Vuelve a iniciar sesión en la app.');
    if (sesiones.size > 500) sesiones.clear();
    sesiones.set(token, { usuarioId: u.id, hasta: Date.now() + 60000 });
    return u.id;
  }

  // ── Cobros ──
  const vista = (p: any, conImagen = false) => ({
    id: String(p.id),
    estado: p.estado,
    monto: Number(p.monto),
    precioOferta: Number(p.precio_oferta),
    montoPrueba: Number(p.monto) !== Number(p.precio_oferta),
    ofertaId: p.offer_id,
    venceEn: p.vence,
    pagadoEn: p.pagado_en || null,
    confirmadoPor: p.confirmado_por || null,
    pago: p.pagador_nombre ? { nombre: p.pagador_nombre } : null,
    ...(conImagen && p.estado === 'pendiente' && p.imagen ? { imagen: p.imagen } : {}),
  });

  async function marcarPagado(p: any, pago: PagoBanco | null, por: string): Promise<boolean> {
    const cambios = { pagado_en: new Date().toISOString(), confirmado_por: por, pagador_nombre: pago?.senderName ?? null, imagen: null };
    try {
      const filas = await db.cambiarSi(p.id, 'pendiente', { ...cambios, estado: 'pagado' });
      if (filas.length) console.log(`Cobro ${p.id} PAGADO · Bs ${p.monto} · oferta ${p.offer_id} · por ${por}`);
      return filas.length > 0;
    } catch (e) {
      // La base no deja dos pagos de la misma oferta: este cobro se pagó de más (hay que devolver)
      if ((e as { codigo?: string }).codigo === '23505') {
        await db.cambiarSi(p.id, 'pendiente', { ...cambios, estado: 'pagado_tarde' });
        console.warn(`Cobro ${p.id}: la oferta ${p.offer_id} ya estaba pagada; queda como pagado_tarde (devolver Bs ${p.monto})`);
        return false;
      }
      throw e;
    }
  }

  // Si el QR pasó su tiempo: última consulta al banco y, si sigue sin pagar, se anula
  async function cerrarSiVencio(p: any, por: string): Promise<boolean> {
    if (p.estado !== 'pendiente' || Date.now() < new Date(p.vence).getTime()) return false;
    if (!p.qr_id) { await db.cambiarSi(p.id, 'pendiente', { estado: 'fallido', imagen: null }); return true; }
    const e = await cfg.banco!.estadoQR(p.qr_id);
    if (e.pagado) { await marcarPagado(p, e.pago, por); return true; }
    if (!e.anulado) await cfg.banco!.anularQR(p.qr_id);
    await db.cambiarSi(p.id, 'pendiente', { estado: 'vencido', imagen: null });
    console.log(`Cobro ${p.id} vencido: QR anulado en el banco`);
    return true;
  }

  // Le pregunta al banco (como mucho cada 3 s por cobro) y devuelve el cobro actualizado
  async function consultar(p: any, forzar = false): Promise<any> {
    if (p.estado !== 'pendiente' || !p.qr_id || !cfg.banco) return p;
    if (!forzar && p.ultima_consulta && Date.now() - new Date(p.ultima_consulta).getTime() < 3000) return p;
    await db.tocar(p.id);
    if (!(await cerrarSiVencio(p, 'pantalla'))) {
      const e = await cfg.banco.estadoQR(p.qr_id);
      if (e.pagado) await marcarPagado(p, e.pago, 'pantalla');
      else if (e.anulado) await db.cambiarSi(p.id, 'pendiente', { estado: 'vencido', imagen: null });
    }
    return (await db.pago(p.id)) || p;
  }

  async function ofertaPagable(ofertaId: number, usuarioId: string) {
    const o = await db.oferta(ofertaId);
    const s = o?.service_requests;
    if (!o || !s || s.client_id !== usuarioId) throw new ErrorHttp(404, 'No encontramos esa oferta entre tus solicitudes.');
    if (o.status !== 'aceptada') throw new ErrorHttp(409, 'Solo se puede pagar una oferta aceptada.');
    if (s.status !== 'completada' && s.work_stage !== 'completado') {
      throw new ErrorHttp(409, 'Todavía no se puede pagar: el técnico tiene que marcar el trabajo como completado.');
    }
    const precio = Math.round(Number(o.price) * 100) / 100;
    if (!(precio > 0)) throw new ErrorHttp(409, 'La oferta no tiene un precio válido.');
    return { id: o.id, precio, solicitudId: o.request_id, tecnicoId: o.technician_id, categoria: s.category || 'Servicio' };
  }

  async function crearCobro(oferta: Awaited<ReturnType<typeof ofertaPagable>>, usuarioId: string) {
    const banco = cfg.banco;
    if (!banco) throw new ErrorHttp(503, 'Los pagos con QR todavía no están configurados.');
    for (let intento = 0; intento < 2; intento++) {
      const previos = await db.pagosDeOferta(oferta.id);
      const pagado = previos.find((c) => c.estado === 'pagado');
      if (pagado) return vista(pagado);
      // QR anterior pendiente: si le quedan más de 2 minutos se muestra el mismo; si no, se cierra
      for (const previo of previos.filter((c) => c.estado === 'pendiente')) {
        const c = await consultar(previo, true);
        if (c.estado === 'pagado') return vista(c);
        if (c.estado !== 'pendiente') continue;
        if (c.qr_id && new Date(c.vence).getTime() - Date.now() > 120000) return vista(c, true);
        if (c.qr_id) {
          const e = await banco.estadoQR(c.qr_id);
          if (e.pagado) { await marcarPagado(c, e.pago, 'pantalla'); return vista((await db.pago(c.id)) || c); }
          if (!e.anulado) await banco.anularQR(c.qr_id);
        }
        await db.cambiarSi(c.id, 'pendiente', { estado: 'vencido', imagen: null });
      }
      const monto = cfg.montoPrueba > 0 ? cfg.montoPrueba : oferta.precio;
      let fila: any;
      try {
        fila = await db.crear({
          offer_id: oferta.id, request_id: oferta.solicitudId, client_id: usuarioId, technician_id: oferta.tecnicoId,
          monto, precio_oferta: oferta.precio, estado: 'pendiente',
          transaction_id: `AY${Date.now().toString(36).toUpperCase()}${randomBytes(2).toString('hex').toUpperCase()}`,
          vence: new Date(Date.now() + vidaMs).toISOString(),
        });
      } catch (e) {
        // Otro toque ya está creando el QR de esta oferta (la base deja uno solo pendiente): se espera y se reintenta
        if ((e as { codigo?: string }).codigo === '23505') { await new Promise((r) => setTimeout(r, 1500)); continue; }
        throw e;
      }
      try {
        const qr = await banco.generarQR({ monto, descripcion: `ArreglaYa ${oferta.categoria} solicitud ${oferta.solicitudId}`, idTransaccion: fila.transaction_id });
        const [actual] = await db.cambiarSi(fila.id, 'pendiente', { qr_id: qr.qrId, imagen: qr.imagenBase64 });
        console.log(`Cobro ${fila.id} creado · Bs ${monto}${monto !== oferta.precio ? ` (prueba; la oferta es Bs ${oferta.precio})` : ''} · oferta ${oferta.id}`);
        return vista(actual || { ...fila, qr_id: qr.qrId, imagen: qr.imagenBase64 }, true);
      } catch (e) {
        await db.cambiarSi(fila.id, 'pendiente', { estado: 'fallido' });
        throw e;
      }
    }
    // Si dos toques chocaron, se devuelve el QR que quedó
    const ultimo = (await db.pagosDeOferta(oferta.id)).find((c) => c.estado === 'pendiente' || c.estado === 'pagado');
    if (ultimo) return vista(ultimo, true);
    throw new ErrorHttp(409, 'No se pudo generar el QR. Prueba de nuevo.');
  }

  // ── Revisión de cada minuto (la llama pg_cron) ──
  async function revisar() {
    const r = { pagados: 0, vencidos: 0, pagadosTarde: 0, errores: 0 };
    if (!cfg.banco) return r;
    const pendientes = await db.pendientes();
    const vencidos = await db.vencidosDesde(new Date(Date.now() - 24 * 3600000).toISOString());
    if (!pendientes.length && !vencidos.length) return r;
    const horaBolivia = new Date(Date.now() - 4 * 3600000).getUTCHours();
    const fechas = horaBolivia < 1 ? [fechaBolivia(), fechaBolivia(-1)] : [fechaBolivia()];
    const pagados = new Map<string, PagoBanco>();
    for (const f of fechas) for (const p of await cfg.banco.pagadosDelDia(f)) pagados.set(String(p.qrId), p);
    let consultas = 0;
    for (const c of pendientes) {
      try {
        if (c.qr_id && pagados.has(c.qr_id)) {
          if (await marcarPagado(c, pagados.get(c.qr_id)!, 'revision')) r.pagados++;
          continue;
        }
        if (Date.now() < new Date(c.vence).getTime() || consultas >= 40) continue;
        consultas++;
        if (await cerrarSiVencio(c, 'revision')) {
          const ahora = await db.pago(c.id);
          if (ahora?.estado === 'pagado') r.pagados++; else r.vencidos++;
        }
      } catch (e) {
        r.errores++;
        console.error(`Revisión del cobro ${c.id}:`, (e as Error).message);
      }
    }
    // QR que el banco cobró después de anularse: hay que devolver la plata
    for (const c of vencidos) {
      if (!c.qr_id || !pagados.has(c.qr_id)) continue;
      const filas = await db.cambiarSi(c.id, 'vencido', { estado: 'pagado_tarde', pagado_en: new Date().toISOString(), confirmado_por: 'revision', pagador_nombre: pagados.get(c.qr_id)?.senderName ?? null });
      if (filas.length) { r.pagadosTarde++; console.warn(`Cobro ${c.id} pagado después de vencer: devolver Bs ${c.monto}`); }
    }
    return r;
  }

  return async function manejar(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const ruta = url.pathname.replace(/^\/functions\/v1/, '').replace(/^\/pagos/, '') || '/';
    try {
      if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
      if (req.method === 'GET' && ruta === '/salud') {
        return json(200, { ok: true, banco: Boolean(cfg.banco), montoPrueba: cfg.montoPrueba, vidaMin: cfg.vidaMin });
      }

      // La app pide el QR del trabajo terminado
      if (req.method === 'POST' && (ruta === '/' || ruta === '')) {
        const usuarioId = await usuarioDe(req);
        const b = await req.json().catch(() => ({}));
        const ofertaId = Number(b?.ofertaId);
        if (!Number.isSafeInteger(ofertaId) || ofertaId <= 0) throw new ErrorHttp(400, 'Falta la oferta.');
        const oferta = await ofertaPagable(ofertaId, usuarioId);
        return json(200, await crearCobro(oferta, usuarioId));
      }

      let m = ruta.match(/^\/oferta\/(\d+)$/);
      if (req.method === 'GET' && m) {
        const usuarioId = await usuarioDe(req);
        const lista = (await db.pagosDeOferta(Number(m[1]))).filter((c) => c.client_id === usuarioId);
        const c = lista.find((x) => x.estado === 'pagado') || lista[lista.length - 1];
        if (!c) return json(200, { estado: 'sin_cobro' });
        return json(200, vista(await consultar(c)));
      }

      m = ruta.match(/^\/(\d+)$/);
      if (req.method === 'GET' && m) {
        const usuarioId = await usuarioDe(req);
        const c = await db.pago(Number(m[1]));
        if (!c || c.client_id !== usuarioId) throw new ErrorHttp(404, 'No existe ese cobro.');
        return json(200, vista(await consultar(c)));
      }

      // Aviso del banco: nunca se confía en el aviso, se le pregunta al banco
      if (req.method === 'POST' && ruta === '/aviso-banco') {
        if (cfg.avisoToken && !String(req.headers.get('authorization') || '').includes(cfg.avisoToken)) {
          return json(401, { responseCode: 1, message: 'No autorizado' });
        }
        const cuerpo = await req.json().catch(() => ({}));
        const p = cuerpo?.payment || cuerpo?.Payment || cuerpo || {};
        const qrId = String(p.qrId || '').trim();
        try {
          const c = qrId && cfg.banco ? await db.pagoPorQr(qrId) : null;
          if (c && c.estado === 'pendiente') {
            const e = await cfg.banco!.estadoQR(qrId);
            if (e.pagado) await marcarPagado(c, e.pago, 'aviso');
          }
          return json(200, { responseCode: 0, message: '' });
        } catch (e) {
          // El banco dijo que ese QR no existe o no es nuestro: aviso falso, se ignora
          if (e instanceof ErrorBanco && e.codigo !== null) return json(200, { responseCode: 0, message: '' });
          console.error('Aviso del banco:', (e as Error).message);
          return json(500, { responseCode: 1, message: 'Error temporal' }); // el banco vuelve a avisar
        }
      }

      if (req.method === 'POST' && ruta === '/revisar') {
        if (!cfg.revisionToken || req.headers.get('x-revision-token') !== cfg.revisionToken) {
          throw new ErrorHttp(403, 'No autorizado.');
        }
        return json(200, await revisar());
      }

      return json(404, { error: 'No existe' });
    } catch (err) {
      if (err instanceof ErrorHttp) return json(err.status, { error: err.message });
      if (err instanceof ErrorBanco) return json(502, { error: `El banco no respondió bien: ${err.message}` });
      console.error(err);
      return json(500, { error: 'Error interno del servidor de pagos.' });
    }
  };
}
