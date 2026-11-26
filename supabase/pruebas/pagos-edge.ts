// Pruebas de la Edge Function «pagos» SIN internet ni plata: banco falso + un Supabase de mentira
// (auth y PostgREST, con las mismas reglas únicas de la tabla pagos_qr).  Uso:  node supabase/pruebas/pagos-edge.ts
import http from 'node:http';
import { createRequire } from 'node:module';
import { BancoEconomico } from '../functions/pagos/baneco.ts';
import { crearManejador } from '../functions/pagos/logica.ts';
import type { Config } from '../functions/pagos/logica.ts';

const require = createRequire(import.meta.url);
const { iniciarBancoFalso } = require('../../servidor-pagos/pruebas/banco-falso.js');

let bien = 0;
let mal = 0;
async function prueba(nombre: string, fn: () => Promise<void> | void) {
  try { await fn(); bien++; console.log(`  ✅ ${nombre}`); } catch (e) { mal++; console.log(`  ❌ ${nombre}\n     ${(e as Error).message}`); }
}
function igual(a: unknown, b: unknown, msg = 'distinto') { if (a !== b) throw new Error(`${msg}: esperaba ${JSON.stringify(b)} y vino ${JSON.stringify(a)}`); }
function cierto(v: unknown, msg = 'esperaba verdadero') { if (!v) throw new Error(msg); }
const dormir = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── Supabase de mentira ──
const CLIENTE = 'aaaaaaaa-0000-0000-0000-000000000001';
const OTRO = 'bbbbbbbb-0000-0000-0000-000000000002';
const TECNICO = 'cccccccc-0000-0000-0000-000000000003';
const TOKENS: Record<string, string> = { 'token-cliente': CLIENTE, 'token-otro': OTRO };
const CLAVE_SERVICIO = 'eyJclave.de.servicio';
const ofertas = new Map<number, any>();
const pagos: any[] = [];
let ofertaSig = 1;
let pagoSig = 1;
function nuevaOferta({ precio = 150, estado = 'aceptada', cliente = CLIENTE, trabajo = 'completado' as string | null } = {}) {
  const id = ofertaSig++;
  ofertas.set(id, {
    id, price: precio, status: estado, request_id: 100 + id, technician_id: TECNICO,
    service_requests: { client_id: cliente, category: 'Plomería', status: trabajo === 'completado' ? 'completada' : 'aceptada', work_stage: trabajo },
  });
  return id;
}
// Las mismas reglas únicas que 011_pagos_qr.sql
function violaUnica(fila: any, excepto?: any) {
  return pagos.some((p) => p !== excepto && (
    (fila.transaction_id && p.transaction_id === fila.transaction_id) ||
    (fila.qr_id && p.qr_id === fila.qr_id) ||
    ((fila.estado === 'pagado' || fila.estado === 'pendiente') && p.estado === fila.estado && p.offer_id === fila.offer_id)));
}
function filtrar(params: URLSearchParams) {
  let filas = pagos.slice();
  for (const [k, v] of params) {
    if (['select', 'order', 'limit'].includes(k)) continue;
    const [op, ...resto] = v.split('.');
    const val = resto.join('.');
    if (op === 'eq') filas = filas.filter((p) => String(p[k]) === val);
    if (op === 'gte') filas = filas.filter((p) => String(p[k]) >= val);
  }
  if (params.get('order') === 'creado.asc') filas.sort((a, b) => a.creado.localeCompare(b.creado) || a.id - b.id);
  if (params.get('limit')) filas = filas.slice(0, Number(params.get('limit')));
  return filas;
}
function iniciarSupabaseFalso(): Promise<{ url: string; cerrar: () => Promise<void> }> {
  const s = http.createServer(async (req, res) => {
    const responder = (st: number, b?: unknown) => { res.writeHead(st, { 'Content-Type': 'application/json' }); res.end(b === undefined ? '' : JSON.stringify(b)); };
    const u = new URL(req.url || '/', 'http://x');
    let cuerpo: any = null;
    const datos = await new Promise<string>((r) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => r(d)); });
    try { cuerpo = datos ? JSON.parse(datos) : null; } catch { /* sin cuerpo */ }
    if (u.pathname === '/auth/v1/user') {
      const usuario = TOKENS[String(req.headers.authorization || '').replace(/^Bearer /, '')];
      return usuario && req.headers.apikey ? responder(200, { id: usuario }) : responder(401, { msg: 'invalid JWT' });
    }
    if (req.headers.apikey !== CLAVE_SERVICIO) return responder(401, { message: 'Invalid API key' });
    if (u.pathname === '/rest/v1/offers') {
      const o = ofertas.get(Number(String(u.searchParams.get('id')).replace('eq.', '')));
      return responder(200, o ? [o] : []);
    }
    if (u.pathname === '/rest/v1/pagos_qr') {
      if (req.method === 'GET') return responder(200, filtrar(u.searchParams));
      if (req.method === 'POST') {
        const fila = { id: pagoSig++, creado: new Date().toISOString(), qr_id: null, imagen: null, pagado_en: null, confirmado_por: null, pagador_nombre: null, ultima_consulta: null, ...cuerpo };
        if (violaUnica(fila)) return responder(409, { code: '23505', message: 'duplicate key value violates unique constraint' });
        pagos.push(fila);
        return responder(201, [fila]);
      }
      if (req.method === 'PATCH') {
        const filas = filtrar(u.searchParams);
        for (const f of filas) if (violaUnica({ ...f, ...cuerpo }, f)) return responder(409, { code: '23505', message: 'duplicate key value violates unique constraint' });
        for (const f of filas) Object.assign(f, cuerpo);
        return responder(200, filas);
      }
    }
    return responder(404, { message: 'no existe' });
  });
  return new Promise((r) => s.listen(0, '127.0.0.1', () => r({
    url: `http://127.0.0.1:${(s.address() as any).port}`,
    cerrar: () => new Promise((c) => s.close(() => c())),
  })));
}

const falso = await iniciarBancoFalso();
const supa = await iniciarSupabaseFalso();
const d = falso.datos;
const banco = new BancoEconomico({ url: falso.url, usuario: d.usuario, clave: d.clave, llaveAes: d.llave, cuenta: d.cuenta });
const base: Config = { banco, supabaseUrl: supa.url, serviceKey: CLAVE_SERVICIO, montoPrueba: 1, vidaMin: 15, avisoToken: '', revisionToken: 'token-del-cron' };
const crear = (extra: Partial<Config> = {}) => crearManejador({ ...base, ...extra });
const f = crear();
async function pedir(manejar: (r: Request) => Promise<Response>, metodo: string, ruta: string, { token = 'token-cliente' as string | null, cuerpo = undefined as unknown, headers = {} as Record<string, string> } = {}) {
  const r = await manejar(new Request(`https://proyecto.supabase.co/functions/v1/pagos${ruta}`, {
    method: metodo,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
  }));
  return { status: r.status, cuerpo: await r.json() as any };
}
const filaDe = (id: string) => pagos.find((p) => String(p.id) === id);

console.log('Permisos y reglas');
const oferta = nuevaOferta();
await prueba('sin iniciar sesión: 401', async () => igual((await pedir(f, 'POST', '', { token: null, cuerpo: { ofertaId: oferta } })).status, 401));
await prueba('token falso: 401', async () => igual((await pedir(f, 'POST', '', { token: 'trucho', cuerpo: { ofertaId: oferta } })).status, 401));
await prueba('oferta de otro cliente: 404', async () => igual((await pedir(f, 'POST', '', { token: 'token-otro', cuerpo: { ofertaId: oferta } })).status, 404));
await prueba('oferta no aceptada: 409', async () => igual((await pedir(f, 'POST', '', { cuerpo: { ofertaId: nuevaOferta({ estado: 'pendiente' }) } })).status, 409));
await prueba('trabajo sin terminar: 409 y lo explica', async () => {
  for (const trabajo of [null, 'en_proceso']) {
    const r = await pedir(f, 'POST', '', { cuerpo: { ofertaId: nuevaOferta({ trabajo }) } });
    igual(r.status, 409, String(trabajo));
    cierto(/marcar el trabajo como completado/.test(r.cuerpo.error), r.cuerpo.error);
  }
});
await prueba('sin los datos del banco: 503', async () => igual((await pedir(crear({ banco: null }), 'POST', '', { cuerpo: { ofertaId: oferta } })).status, 503));

console.log('Cobro');
let cobro: any;
await prueba('genera el QR por el monto de prueba (y muestra el precio real)', async () => {
  const r = await pedir(f, 'POST', '', { cuerpo: { ofertaId: oferta } });
  igual(r.status, 200, JSON.stringify(r.cuerpo));
  cobro = r.cuerpo;
  igual(typeof cobro.id, 'string');
  igual(cobro.estado, 'pendiente');
  igual(cobro.monto, 1);
  igual(cobro.precioOferta, 150);
  igual(cobro.montoPrueba, true);
  cierto(cobro.imagen && cobro.imagen.length > 10, 'falta la imagen');
  igual(filaDe(cobro.id).technician_id, TECNICO, 'técnico guardado');
});
await prueba('pedir de nuevo devuelve el MISMO QR', async () => {
  igual((await pedir(f, 'POST', '', { cuerpo: { ofertaId: oferta } })).cuerpo.id, cobro.id);
  igual(pagos.filter((p) => p.offer_id === oferta).length, 1);
});
await prueba('dos toques a la vez generan un solo QR', async () => {
  const o = nuevaOferta();
  const [a, b] = await Promise.all([pedir(f, 'POST', '', { cuerpo: { ofertaId: o } }), pedir(f, 'POST', '', { cuerpo: { ofertaId: o } })]);
  igual(a.cuerpo.id, b.cuerpo.id);
  igual(pagos.filter((p) => p.offer_id === o && p.estado === 'pendiente').length, 1);
});
await prueba('otro usuario no ve el cobro: 404', async () => igual((await pedir(f, 'GET', `/${cobro.id}`, { token: 'token-otro' })).status, 404));
await prueba('antes de pagar: pendiente y sin repetir la imagen', async () => {
  const r = await pedir(f, 'GET', `/${cobro.id}`);
  igual(r.cuerpo.estado, 'pendiente');
  igual(r.cuerpo.imagen, undefined);
});
await prueba('al pagar en el banco, la pantalla se entera: pagado', async () => {
  falso.pagar(filaDe(cobro.id).qr_id);
  await dormir(3100);
  const r = await pedir(f, 'GET', `/${cobro.id}`);
  igual(r.cuerpo.estado, 'pagado');
  igual(r.cuerpo.confirmadoPor, 'pantalla');
  igual(r.cuerpo.pago?.nombre, 'CLIENTE DE PRUEBA');
});
await prueba('una oferta pagada no se cobra dos veces', async () => {
  const r = await pedir(f, 'POST', '', { cuerpo: { ofertaId: oferta } });
  igual(r.cuerpo.estado, 'pagado');
  igual(pagos.filter((p) => p.offer_id === oferta).length, 1);
});
await prueba('la solicitud ve «pagado»', async () => igual((await pedir(f, 'GET', `/oferta/${oferta}`)).cuerpo.estado, 'pagado'));
await prueba('una oferta sin cobro dice «sin_cobro»', async () => igual((await pedir(f, 'GET', `/oferta/${nuevaOferta()}`)).cuerpo.estado, 'sin_cobro'));

console.log('Aviso del banco y revisión de cada minuto');
await prueba('la revisión sin el token del cron: 403', async () => igual((await pedir(f, 'POST', '/revisar', { token: null })).status, 403));
await prueba('la revisión confirma un pago aunque nadie mire la pantalla', async () => {
  const r = await pedir(f, 'POST', '', { cuerpo: { ofertaId: nuevaOferta() } });
  falso.pagar(filaDe(r.cuerpo.id).qr_id);
  const rev = await pedir(f, 'POST', '/revisar', { token: null, headers: { 'x-revision-token': 'token-del-cron' } });
  igual(rev.cuerpo.pagados, 1);
  igual(filaDe(r.cuerpo.id).confirmado_por, 'revision');
});
await prueba('aviso falso no marca nada; aviso verdadero confirma', async () => {
  const r = await pedir(f, 'POST', '', { cuerpo: { ofertaId: nuevaOferta() } });
  const qrId = filaDe(r.cuerpo.id).qr_id;
  let a = await pedir(f, 'POST', '/aviso-banco', { token: null, cuerpo: { payment: { qrId } } });
  igual(a.cuerpo.responseCode, 0);
  igual(filaDe(r.cuerpo.id).estado, 'pendiente', 'aviso falso');
  falso.pagar(qrId);
  a = await pedir(f, 'POST', '/aviso-banco', { token: null, cuerpo: { payment: { qrId } } });
  igual(a.cuerpo.responseCode, 0);
  igual(filaDe(r.cuerpo.id).confirmado_por, 'aviso');
});
await prueba('aviso con token equivocado: 401', async () => {
  const r = await pedir(crear({ avisoToken: 'secreto' }), 'POST', '/aviso-banco', { token: 'otro', cuerpo: { payment: { qrId: '1' } } });
  igual(r.status, 401);
});

console.log('Vencimiento');
const corto = crear({ vidaMin: 0.002 }); // 120 ms
await prueba('un QR vencido sin pagar se anula en el banco', async () => {
  const r = await pedir(corto, 'POST', '', { cuerpo: { ofertaId: nuevaOferta() } });
  await dormir(200);
  const rev = await pedir(corto, 'POST', '/revisar', { token: null, headers: { 'x-revision-token': 'token-del-cron' } });
  igual(rev.cuerpo.vencidos, 1);
  igual(filaDe(r.cuerpo.id).estado, 'vencido');
  igual(falso.estadoDe(filaDe(r.cuerpo.id).qr_id), 9, 'anulado en el banco');
});
await prueba('pagado justo antes de vencer: queda PAGADO', async () => {
  const r = await pedir(corto, 'POST', '', { cuerpo: { ofertaId: nuevaOferta() } });
  falso.pagar(filaDe(r.cuerpo.id).qr_id);
  await dormir(200);
  igual((await pedir(corto, 'GET', `/${r.cuerpo.id}`)).cuerpo.estado, 'pagado');
});
await prueba('después de vencer, «Pagar» genera otro QR y el viejo queda anulado', async () => {
  const o = nuevaOferta();
  const a = await pedir(corto, 'POST', '', { cuerpo: { ofertaId: o } });
  await dormir(200);
  const b = await pedir(corto, 'POST', '', { cuerpo: { ofertaId: o } });
  cierto(a.cuerpo.id !== b.cuerpo.id, 'tenía que ser otro cobro');
  igual(falso.estadoDe(filaDe(a.cuerpo.id).qr_id), 9);
});

console.log('Monto y doble pago');
await prueba('con MONTO_PRUEBA=0 cobra el precio de la oferta', async () => {
  const r = await pedir(crear({ montoPrueba: 0 }), 'POST', '', { cuerpo: { ofertaId: nuevaOferta({ precio: 85.5 }) } });
  igual(r.cuerpo.monto, 85.5);
  igual(r.cuerpo.montoPrueba, false);
});
await prueba('si un segundo QR de la misma oferta se paga, queda «pagado_tarde» (para devolver)', async () => {
  const o = nuevaOferta();
  const a = await pedir(f, 'POST', '', { cuerpo: { ofertaId: o } });
  // Un QR viejo que quedó pendiente (por ejemplo de antes de un corte) y se paga después del primero
  const viejo = { id: pagoSig++, offer_id: o, request_id: 100 + o, client_id: CLIENTE, technician_id: TECNICO, monto: 1, precio_oferta: 150, estado: 'vencido', transaction_id: 'VIEJO1', qr_id: null as string | null, creado: new Date().toISOString(), vence: new Date(Date.now() + 600000).toISOString(), ultima_consulta: null };
  const qrViejo = await banco.generarQR({ monto: 1, descripcion: 'viejo', idTransaccion: 'VIEJO1' });
  viejo.qr_id = qrViejo.qrId;
  pagos.push(viejo);
  falso.pagar(filaDe(a.cuerpo.id).qr_id);
  await dormir(3100);
  igual((await pedir(f, 'GET', `/${a.cuerpo.id}`)).cuerpo.estado, 'pagado');
  viejo.estado = 'pendiente';
  falso.pagar(qrViejo.qrId);
  const r = await pedir(f, 'GET', `/${viejo.id}`);
  igual(r.cuerpo.estado, 'pagado_tarde');
  igual(pagos.filter((p) => p.offer_id === o && p.estado === 'pagado').length, 1, 'un solo pagado');
});
await prueba('la URL de salud responde', async () => igual((await pedir(f, 'GET', '/salud', { token: null })).cuerpo.ok, true));

await falso.cerrar();
await supa.cerrar();
console.log(`\n${mal ? '❌' : '✅'} ${bien} bien, ${mal} mal`);
process.exit(mal ? 1 : 0);
