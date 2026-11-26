'use strict';
/**
 * SERVIDOR DE PAGOS DE ARREGLAYA — cobra con QR del Banco Económico.
 *
 * La app Flutter NO habla con el banco: las claves del banco viven solo acá (en servidor-pagos/.env).
 * La app le pide a este servidor un QR para una oferta aceptada y pregunta cada 3 s si ya se pagó.
 *
 * Un pago se confirma por tres caminos, y cualquiera alcanza (el cobro se marca pagado UNA sola vez):
 *   1. La pantalla de la app pregunta cada 3 s                     → GET  /api/pagos/:id
 *   2. El banco avisa a la «URL de notificación» (si se registró)  → POST /aviso-banco
 *   3. Una revisión cada minuto mira la lista de pagados del banco → revisar()
 * La revisión también anula los QR que pasaron su tiempo sin pagarse (el banco los vence por día, no por minutos).
 *
 * Seguridad: cada pedido trae el token de sesión de Supabase del usuario. Con ese token (y la clave PUBLICABLE)
 * se le pregunta a Supabase quién es y cuánto vale la oferta; RLS de Supabase solo deja ver lo que es suyo.
 * El monto lo pone el servidor, nunca la app.
 *
 * Uso:   node servidor.js            → con los datos del banco del .env
 *        node servidor.js --falso    → con un banco de mentira (sin plata), para ver el recorrido
 */
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { desdeEnv, fechaBolivia, respuestaAviso, URL_PRODUCCION, URL_PRUEBAS } = require('./src/baneco');
const { cargarEnv } = require('./src/cargar-env');

// Proyecto de Supabase de ArreglaYa (los mismos valores por defecto que lib/main.dart; la clave es la PUBLICABLE)
const SUPABASE_URL_POR_DEFECTO = 'https://prdzxcybmcxprzjsovuy.supabase.co';
const SUPABASE_KEY_POR_DEFECTO = 'sb_publishable_1hBCuPZMicJRBQiSON3_2A_-x2_uOZu';

class ErrorHttp extends Error {
  constructor(status, mensaje) { super(mensaje); this.status = status; }
}

// ── Dónde se guardan los cobros: un archivo JSON (para una prueba alcanza; en serio iría en la base) ──
function crearAlmacen(archivo) {
  let cobros = {};
  try { cobros = JSON.parse(fs.readFileSync(archivo, 'utf8')); } catch { /* todavía no hay cobros */ }
  const escribir = () => {
    fs.mkdirSync(path.dirname(archivo), { recursive: true });
    fs.writeFileSync(`${archivo}.tmp`, JSON.stringify(cobros, null, 2));
    fs.renameSync(`${archivo}.tmp`, archivo);
  };
  return {
    todos: () => Object.values(cobros),
    buscar: (id) => cobros[id] || null,
    porQr: (qrId) => Object.values(cobros).find((c) => c.qrId === String(qrId)) || null,
    deOferta: (ofertaId) => Object.values(cobros).filter((c) => c.ofertaId === ofertaId).sort((a, b) => a.creado.localeCompare(b.creado)),
    guardar: (c) => { cobros[c.id] = c; escribir(); return c; },
  };
}

function leerJson(req, max = 20000) {
  return new Promise((resolver, rechazar) => {
    let datos = '';
    req.on('data', (c) => { datos += c; if (datos.length > max) { rechazar(new ErrorHttp(413, 'Pedido demasiado grande')); req.destroy(); } });
    req.on('end', () => { try { resolver(datos ? JSON.parse(datos) : {}); } catch { rechazar(new ErrorHttp(400, 'JSON inválido')); } });
    req.on('error', rechazar);
  });
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type',
};
function responder(res, status, cuerpo, tipo = 'application/json') {
  res.writeHead(status, { 'Content-Type': `${tipo}; charset=utf-8`, 'Cache-Control': 'no-store', ...CORS });
  res.end(tipo === 'application/json' ? JSON.stringify(cuerpo) : cuerpo);
}

const esLocal = (req) => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress);

// Del pago que informa el banco se guarda solo lo necesario para mostrarlo
const resumenPago = (p) => (p ? {
  monto: p.amount ?? null, fecha: p.paymentDate ?? null, hora: p.paymentTime ?? null,
  nombre: p.senderName ?? null, banco: p.senderBankCode ?? null,
} : null);

/**
 * @param {object} op
 * @param {import('./src/baneco').BancoEconomico} op.banco
 * @param {string} op.archivo            Archivo JSON de los cobros.
 * @param {number} [op.puerto]           0 = cualquiera libre (pruebas).
 * @param {string} [op.host]             '0.0.0.0' para que el celular lo vea por Wi-Fi.
 * @param {string} [op.supabaseUrl]
 * @param {string} [op.supabaseKey]      Clave PUBLICABLE de Supabase (nunca la service_role).
 * @param {number} [op.montoPrueba]      Si es > 0, todos los QR salen por este monto (la oferta real se muestra aparte).
 * @param {number} [op.vidaMin]          Minutos que vale un QR antes de anularlo.
 * @param {number} [op.revisarCadaMs]    0 = no correr la revisión sola.
 * @param {string} [op.avisoToken]       Si se registró un token en el banco, el aviso tiene que traerlo.
 * @param {(cobro: object) => Promise<void>} [op.alPagar]
 * @param {object} [op.demo]             { pagar(qrId) } del banco falso: agrega «Simular pago» en la página de inicio.
 */
function iniciarServidor({
  banco, archivo, puerto = 3100, host = '0.0.0.0',
  supabaseUrl = SUPABASE_URL_POR_DEFECTO, supabaseKey = SUPABASE_KEY_POR_DEFECTO,
  montoPrueba = 0, vidaMin = 10, revisarCadaMs = 60000, avisoToken = '',
  alPagar = async (c) => console.log(`✅ Cobro ${c.id} PAGADO · Bs ${c.monto} · oferta ${c.ofertaId} · confirmado por: ${c.confirmadoPor}`),
  demo = null,
}) {
  const almacen = crearAlmacen(archivo);
  const vidaMs = vidaMin * 60000;
  const supa = String(supabaseUrl).replace(/\/$/, '');
  const ultimaConsulta = new Map(); // no preguntarle al banco más de una vez cada 3 s por el mismo cobro
  const sesiones = new Map(); // token → { usuarioId, hasta }: no preguntarle a Supabase en cada consulta
  const bloqueos = new Map(); // ofertaId → promesa: dos toques seguidos no generan dos QR

  // ── Supabase: quién es el usuario y qué oferta quiere pagar ──
  async function supabase(ruta, token) {
    let r;
    try {
      r = await fetch(`${supa}${ruta}`, {
        headers: { apikey: supabaseKey, Authorization: `Bearer ${token}`, Accept: 'application/json' },
        signal: AbortSignal.timeout(10000),
      });
    } catch {
      throw new ErrorHttp(502, 'No se pudo hablar con Supabase para verificar tu sesión. Probá de nuevo.');
    }
    if (r.status === 401 || r.status === 403) throw new ErrorHttp(401, 'Tu sesión venció. Volvé a iniciar sesión en la app.');
    if (!r.ok) throw new ErrorHttp(502, `Supabase respondió ${r.status}`);
    return r.json();
  }

  async function usuarioDe(req) {
    const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
    if (!token) throw new ErrorHttp(401, 'Falta iniciar sesión.');
    const s = sesiones.get(token);
    if (s && s.hasta > Date.now()) return { usuarioId: s.usuarioId, token };
    const u = await supabase('/auth/v1/user', token);
    if (!u || !u.id) throw new ErrorHttp(401, 'Tu sesión venció. Volvé a iniciar sesión en la app.');
    if (sesiones.size > 500) sesiones.clear();
    sesiones.set(token, { usuarioId: u.id, hasta: Date.now() + 60000 });
    return { usuarioId: u.id, token };
  }

  async function ofertaPagable(ofertaId, { usuarioId, token }) {
    const filas = await supabase(
      `/rest/v1/offers?id=eq.${ofertaId}&select=id,price,status,request_id,service_requests(client_id,category,status,work_stage)`,
      token,
    );
    const o = Array.isArray(filas) ? filas[0] : null;
    // RLS de Supabase ya esconde las ofertas ajenas; igual se revisa que la solicitud sea de este usuario
    if (!o || !o.service_requests || o.service_requests.client_id !== usuarioId) throw new ErrorHttp(404, 'No encontramos esa oferta entre tus solicitudes.');
    if (o.status !== 'aceptada') throw new ErrorHttp(409, 'Solo se puede pagar una oferta aceptada.');
    // Se paga cuando el trabajo está hecho: el técnico lo marca como completado desde su app
    const s = o.service_requests;
    if (s.status !== 'completada' && s.work_stage !== 'completado') {
      throw new ErrorHttp(409, 'Todavía no se puede pagar: el técnico tiene que marcar el trabajo como completado.');
    }
    const precio = Math.round(Number(o.price) * 100) / 100;
    if (!(precio > 0)) throw new ErrorHttp(409, 'La oferta no tiene un precio válido.');
    return { id: o.id, precio, solicitudId: o.request_id, categoria: o.service_requests.category || 'Servicio' };
  }

  // ── Cobros ──
  const venceEn = (c) => new Date(new Date(c.creado).getTime() + vidaMs).toISOString();
  const vista = (c, conImagen = false) => ({
    id: c.id, estado: c.estado, monto: c.monto, precioOferta: c.precioOferta, montoPrueba: c.monto !== c.precioOferta,
    ofertaId: c.ofertaId, venceEn: venceEn(c), pagadoEn: c.pagadoEn || null, confirmadoPor: c.confirmadoPor || null,
    pago: c.pago || null, ...(conImagen ? { imagen: c.imagen } : {}),
  });

  // Marca pagado UNA sola vez, venga de donde venga la confirmación
  async function marcarPagado(c, pago, por) {
    if (c.estado === 'pagado') return false;
    Object.assign(c, { estado: 'pagado', pagadoEn: new Date().toISOString(), confirmadoPor: por, pago: resumenPago(pago) });
    delete c.imagen; // ya no hace falta mostrar el QR
    almacen.guardar(c);
    try { await alPagar(c); } catch (e) { console.error(`Error después de cobrar ${c.id}:`, e.message); }
    return true;
  }

  // Si el QR pasó su tiempo: última consulta al banco y, si sigue sin pagar, se anula
  async function cerrarSiVencio(c, por) {
    if (c.estado !== 'pendiente' || Date.now() - new Date(c.creado).getTime() < vidaMs) return false;
    const e = await banco.estadoQR(c.qrId);
    if (e.pagado) { await marcarPagado(c, e.pago, por); return true; }
    if (!e.anulado) await banco.anularQR(c.qrId);
    delete c.imagen;
    almacen.guardar(Object.assign(c, { estado: 'vencido' }));
    console.log(`⌛ Cobro ${c.id} vencido: QR anulado en el banco`);
    return true;
  }

  async function consultar(c, forzar = false) {
    if (c.estado !== 'pendiente') return c;
    const antes = ultimaConsulta.get(c.id) || 0;
    if (!forzar && Date.now() - antes < 3000) return c;
    ultimaConsulta.set(c.id, Date.now());
    if (await cerrarSiVencio(c, 'pantalla')) return c;
    const e = await banco.estadoQR(c.qrId);
    if (e.pagado) await marcarPagado(c, e.pago, 'pantalla');
    else if (e.anulado) { delete c.imagen; almacen.guardar(Object.assign(c, { estado: 'vencido' })); }
    return c;
  }

  async function crearCobro(oferta, usuarioId) {
    const previos = almacen.deOferta(oferta.id);
    // ¿Ya está pagada? No se cobra dos veces
    const pagado = previos.find((c) => c.estado === 'pagado');
    if (pagado) return vista(pagado);
    // Un QR anterior todavía pendiente: si sigue vigente se muestra el mismo; si no, se cierra antes de hacer otro
    for (const c of previos.filter((x) => x.estado === 'pendiente')) {
      await consultar(c, true);
      if (c.estado === 'pagado') return vista(c);
      if (c.estado === 'pendiente') {
        // Le quedan más de 2 minutos: se reutiliza (así nunca hay dos QR pagables para la misma oferta)
        if (new Date(venceEn(c)).getTime() - Date.now() > 120000 && c.usuarioId === usuarioId) return vista(c, true);
        const e = await banco.estadoQR(c.qrId);
        if (e.pagado) { await marcarPagado(c, e.pago, 'pantalla'); return vista(c); }
        if (!e.anulado) await banco.anularQR(c.qrId);
        delete c.imagen;
        almacen.guardar(Object.assign(c, { estado: 'vencido' }));
      }
    }
    const monto = montoPrueba > 0 ? montoPrueba : oferta.precio;
    const id = `AY${Date.now().toString(36).toUpperCase()}${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
    const descripcion = `ArreglaYa ${oferta.categoria} solicitud ${oferta.solicitudId}`;
    const qr = await banco.generarQR({ monto, descripcion, idTransaccion: id });
    const c = almacen.guardar({
      id, ofertaId: oferta.id, solicitudId: oferta.solicitudId, usuarioId, qrId: qr.qrId,
      monto, precioOferta: oferta.precio, descripcion, estado: 'pendiente', creado: new Date().toISOString(), imagen: qr.imagenBase64,
    });
    console.log(`🧾 Cobro ${id} creado · Bs ${monto}${monto !== oferta.precio ? ` (prueba; la oferta es Bs ${oferta.precio})` : ''} · oferta ${oferta.id}`);
    return vista(c, true);
  }

  // Cobro de la página de prueba (sin app ni oferta): siempre por el monto de prueba, Bs 1 si no hay otro
  async function crearCobroPrueba() {
    const monto = montoPrueba > 0 ? montoPrueba : 1;
    const id = `AY${Date.now().toString(36).toUpperCase()}${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
    const descripcion = 'ArreglaYa prueba de pago';
    const qr = await banco.generarQR({ monto, descripcion, idTransaccion: id });
    const c = almacen.guardar({
      id, ofertaId: null, solicitudId: null, usuarioId: 'prueba-local', origen: 'prueba', qrId: qr.qrId,
      monto, precioOferta: monto, descripcion, estado: 'pendiente', creado: new Date().toISOString(), imagen: qr.imagenBase64,
    });
    console.log(`🧾 Cobro ${id} creado desde la página de prueba · Bs ${monto}`);
    return vista(c, true);
  }

  function conBloqueo(clave, fn) {
    const antes = bloqueos.get(clave) || Promise.resolve();
    const ahora = antes.catch(() => {}).then(fn);
    const fin = ahora.catch(() => {}).finally(() => { if (bloqueos.get(clave) === fin) bloqueos.delete(clave); });
    bloqueos.set(clave, fin);
    return ahora;
  }

  // ── Revisión de cada minuto ──
  let revisando = false;
  async function revisar() {
    if (revisando) return { salteada: true };
    revisando = true;
    const r = { pagados: 0, vencidos: 0, errores: 0 };
    try {
      const pendientes = almacen.todos().filter((c) => c.estado === 'pendiente');
      if (!pendientes.length) return r;
      // Lista de pagados del banco: hoy, y en la primera hora del día también ayer
      const horaBolivia = new Date(Date.now() - 4 * 3600000).getUTCHours();
      const fechas = horaBolivia < 1 ? [fechaBolivia(), fechaBolivia(-1)] : [fechaBolivia()];
      const pagados = new Map();
      for (const f of fechas) for (const p of await banco.pagadosDelDia(f)) pagados.set(String(p.qrId), p);
      let consultas = 0;
      for (const c of pendientes) {
        if (pagados.has(c.qrId)) {
          if (await marcarPagado(c, pagados.get(c.qrId), 'revision')) r.pagados++;
          continue;
        }
        if (Date.now() - new Date(c.creado).getTime() < vidaMs || consultas >= 40) continue;
        consultas++;
        try {
          await cerrarSiVencio(c, 'revision');
          if (c.estado === 'pagado') r.pagados++;
          else if (c.estado === 'vencido') r.vencidos++;
        } catch (err) {
          r.errores++;
          console.error(`Revisión del cobro ${c.id}:`, err.message);
        }
      }
    } catch (err) {
      r.errores++;
      console.error('Revisión:', err.message);
    } finally {
      revisando = false;
    }
    return r;
  }

  // ── Página de inicio: para ver de un vistazo que el servidor está prendido ──
  function paginaInicio() {
    const cobros = almacen.todos().sort((a, b) => b.creado.localeCompare(a.creado)).slice(0, 15);
    const esc = (s) => String(s).replace(/[&<>"]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));
    const filas = cobros.map((c) => `<tr><td>${esc(c.id)}</td><td>Bs ${esc(c.monto)}</td><td class="${esc(c.estado)}">${esc(c.estado)}</td>`
      + `<td>${esc(new Date(c.creado).toLocaleString('es-BO', { timeZone: 'America/La_Paz' }))}</td><td>${esc(c.confirmadoPor || '')}</td>`
      + `<td>${demo && c.estado === 'pendiente' ? `<form method="post" action="/demo/pagar/${esc(c.id)}"><button>Simular pago</button></form>` : ''}</td></tr>`).join('');
    const bancoTxt = banco.url === URL_PRODUCCION ? 'Banco Económico (producción: plata real)'
      : banco.url === URL_PRUEBAS ? 'Banco Económico (servidor de pruebas)' : 'banco de mentira (sin plata)';
    return `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pagos ArreglaYa</title>${demo ? '<meta http-equiv="refresh" content="5">' : ''}<style>
body{font-family:system-ui,sans-serif;max-width:860px;margin:32px auto;padding:0 16px;color:#1d2b2a}
h1{color:#075E54;margin-bottom:4px}table{border-collapse:collapse;width:100%;margin-top:16px;font-size:14px}
td,th{border-bottom:1px solid #dde5e4;padding:8px;text-align:left}.pagado{color:#1b7f3b;font-weight:700}
.vencido{color:#8a8f8e}.pendiente{color:#b26a00;font-weight:600}button{background:#075E54;color:#fff;border:0;border-radius:6px;padding:6px 10px;cursor:pointer}
</style></head><body><h1>Servidor de pagos ArreglaYa</h1>
<p>Prendido · cobra con: <b>${esc(bancoTxt)}</b> · ${montoPrueba > 0 ? `<b>modo prueba: cada QR sale por Bs ${esc(montoPrueba)}</b>` : 'cobra el precio de la oferta'} · los QR valen ${esc(vidaMin)} min</p>
<p><a href="/prueba">Página de prueba</a>: genera un QR sin la app (solo desde esta PC).</p>
${cobros.length ? `<table><tr><th>Cobro</th><th>Monto</th><th>Estado</th><th>Creado</th><th>Confirmado por</th><th></th></tr>${filas}</table>` : '<p>Todavía no hay cobros. Pedí uno desde la app (oferta aceptada → «Pagar con QR») o desde la página de prueba.</p>'}
</body></html>`;
  }

  const servidor = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (req.method === 'OPTIONS') { res.writeHead(204, CORS); return res.end(); }
      if (req.method === 'GET' && url.pathname === '/') return responder(res, 200, paginaInicio(), 'text/html');
      if (req.method === 'GET' && url.pathname === '/salud') return responder(res, 200, { ok: true, montoPrueba, vidaMin });

      // ── Página de prueba: solo desde esta PC (si no, cualquiera en el Wi-Fi podría generar QR) ──
      if (url.pathname === '/prueba' || url.pathname.startsWith('/prueba/')) {
        if (!esLocal(req)) throw new ErrorHttp(403, 'La página de prueba solo se abre desde la PC del servidor.');
        if (req.method === 'GET' && url.pathname === '/prueba') {
          return responder(res, 200, fs.readFileSync(path.join(__dirname, 'prueba.html'), 'utf8'), 'text/html');
        }
        if (req.method === 'GET' && url.pathname === '/prueba/info') {
          const tipo = banco.url === URL_PRODUCCION ? 'produccion' : banco.url === URL_PRUEBAS ? 'pruebas' : 'otro';
          return responder(res, 200, { banco: demo ? 'falso' : tipo, monto: montoPrueba > 0 ? montoPrueba : 1, vidaMin, demo: !!demo });
        }
        if (req.method === 'POST' && url.pathname === '/prueba/cobro') return responder(res, 200, await crearCobroPrueba());
        const mp = url.pathname.match(/^\/prueba\/cobro\/(AY[A-Z0-9]+)$/);
        if (req.method === 'GET' && mp) {
          const c = almacen.buscar(mp[1]);
          if (!c || c.origen !== 'prueba') throw new ErrorHttp(404, 'No existe ese cobro.');
          await consultar(c);
          return responder(res, 200, vista(c));
        }
        throw new ErrorHttp(404, 'No existe');
      }

      // La app pide el QR de una oferta aceptada
      if (req.method === 'POST' && url.pathname === '/api/pagos') {
        const u = await usuarioDe(req);
        const b = await leerJson(req);
        const ofertaId = Number(b.ofertaId);
        if (!Number.isSafeInteger(ofertaId) || ofertaId <= 0) throw new ErrorHttp(400, 'Falta la oferta.');
        const oferta = await ofertaPagable(ofertaId, u);
        return responder(res, 200, await conBloqueo(ofertaId, () => crearCobro(oferta, u.usuarioId)));
      }

      // ¿Ya pagó? (la app pregunta cada 3 s)
      let m = url.pathname.match(/^\/api\/pagos\/(AY[A-Z0-9]+)$/);
      if (req.method === 'GET' && m) {
        const u = await usuarioDe(req);
        const c = almacen.buscar(m[1]);
        if (!c || c.usuarioId !== u.usuarioId) throw new ErrorHttp(404, 'No existe ese cobro.');
        await consultar(c);
        return responder(res, 200, vista(c)); // sin la imagen: la app ya la tiene desde que pidió el QR
      }

      // Estado del pago de una oferta (para mostrar «Pagado» en la tarjeta de la oferta)
      m = url.pathname.match(/^\/api\/pagos\/oferta\/(\d+)$/);
      if (req.method === 'GET' && m) {
        const u = await usuarioDe(req);
        const lista = almacen.deOferta(Number(m[1])).filter((c) => c.usuarioId === u.usuarioId);
        const c = lista.find((x) => x.estado === 'pagado') || lista[lista.length - 1];
        if (!c) return responder(res, 200, { estado: 'sin_cobro' });
        await consultar(c);
        return responder(res, 200, vista(c));
      }

      // Aviso del banco. Nunca se confía en el aviso: verificarAviso le pregunta al banco si de verdad está pagado
      if (req.method === 'POST' && url.pathname === '/aviso-banco') {
        if (avisoToken && !String(req.headers.authorization || '').includes(avisoToken)) {
          return responder(res, 401, { responseCode: 1, message: 'No autorizado' });
        }
        const cuerpo = await leerJson(req, 100000).catch(() => ({}));
        try {
          const v = await banco.verificarAviso(cuerpo);
          const c = v.qrId && almacen.porQr(v.qrId);
          if (v.pagado && c) await marcarPagado(c, v.pago, 'aviso');
          return responder(res, 200, respuestaAviso(true));
        } catch (err) {
          console.error('Aviso del banco:', err.message);
          return responder(res, 500, respuestaAviso(false)); // el banco vuelve a avisar
        }
      }

      // Solo con el banco falso: botón «Simular pago» de la página de inicio
      m = url.pathname.match(/^\/demo\/pagar\/(AY[A-Z0-9]+)$/);
      if (demo && req.method === 'POST' && m) {
        const c = almacen.buscar(m[1]);
        if (c) demo.pagar(c.qrId);
        res.writeHead(303, { Location: '/' });
        return res.end();
      }

      return responder(res, 404, { error: 'No existe' });
    } catch (err) {
      if (err instanceof ErrorHttp) return responder(res, err.status, { error: err.message });
      console.error(err);
      const delBanco = err && err.name === 'ErrorBanco';
      return responder(res, 502, { error: delBanco ? `El banco no respondió bien: ${err.message}` : 'Error interno del servidor de pagos.' });
    }
  });

  const reloj = revisarCadaMs > 0 ? setInterval(() => revisar().catch(() => {}), revisarCadaMs) : null;
  return new Promise((resolver) => {
    servidor.listen(puerto, host, () => {
      resolver({
        servidor, revisar, almacen, puerto: servidor.address().port,
        cerrar: () => new Promise((r) => { if (reloj) clearInterval(reloj); servidor.close(() => r()); }),
      });
    });
  });
}

module.exports = { iniciarServidor, crearAlmacen };

// Direcciones de esta PC en la red (para poner en PAGOS_URL al compilar la app)
function ipsDeRed() {
  return Object.values(os.networkInterfaces()).flat().filter((i) => i && i.family === 'IPv4' && !i.internal).map((i) => i.address);
}

if (require.main === module) {
  (async () => {
    cargarEnv(path.join(__dirname, '.env'));
    const falso = process.argv.includes('--falso');
    let banco;
    let demo = null;
    if (falso) {
      const { iniciarBancoFalso } = require('./pruebas/banco-falso');
      const b = await iniciarBancoFalso({ puerto: 0 });
      const { BancoEconomico } = require('./src/baneco');
      banco = new BancoEconomico({ url: b.url, usuario: b.datos.usuario, clave: b.datos.clave, llaveAes: b.datos.llave, cuenta: b.datos.cuenta, prefijo: 'AY' });
      demo = b;
    } else {
      try {
        banco = desdeEnv({ BANECO_PREFIJO: 'AY', ...process.env });
      } catch (e) {
        console.log(`❌ ${e.message}.\n   Corré primero:  node configurar.js   (o probá sin plata con:  node servidor.js --falso)`);
        process.exit(1);
      }
    }
    const puerto = Number(process.env.PUERTO) || 3100;
    const montoPrueba = process.env.MONTO_PRUEBA === undefined ? 1 : Number(process.env.MONTO_PRUEBA) || 0;
    const s = await iniciarServidor({
      banco, demo, puerto,
      archivo: path.join(__dirname, 'datos', falso ? 'cobros-falso.json' : 'cobros.json'),
      supabaseUrl: process.env.SUPABASE_URL || SUPABASE_URL_POR_DEFECTO,
      supabaseKey: process.env.SUPABASE_ANON_KEY || SUPABASE_KEY_POR_DEFECTO,
      montoPrueba,
      vidaMin: Number(process.env.QR_VIDA_MINUTOS) || 10,
      avisoToken: process.env.BANECO_AVISO_TOKEN || '',
    });
    console.log(`Servidor de pagos ArreglaYa prendido en el puerto ${s.puerto}`);
    console.log(`  Banco: ${falso ? 'DE MENTIRA (sin plata) — en http://localhost:' + s.puerto + ' hay botones «Simular pago»' : banco.url}`);
    console.log(`  ${montoPrueba > 0 ? `Modo prueba: cada QR sale por Bs ${montoPrueba}` : 'Cobra el precio de la oferta'}`);
    const ips = ipsDeRed();
    if (ips.length) {
      console.log('  Para la app, compilá con una de estas (la del Wi-Fi):');
      for (const ip of ips) console.log(`    --dart-define=PAGOS_URL=http://${ip}:${s.puerto}`);
    }
  })().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
}
