'use strict';
/**
 * Pruebas del servidor de pagos contra el BANCO FALSO y un Supabase de mentira (sin internet ni plata).
 * Uso:  npm test   (desde servidor-pagos)
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { BancoEconomico } = require('../src/baneco');
const { iniciarBancoFalso } = require('./banco-falso');
const { iniciarServidor } = require('../servidor');

let bien = 0;
let mal = 0;
async function prueba(nombre, fn) {
  try { await fn(); bien++; console.log(`  ✅ ${nombre}`); } catch (e) { mal++; console.log(`  ❌ ${nombre}\n     ${e.message}`); }
}
const igual = (a, b, msg) => { if (a !== b) throw new Error(`${msg || 'distinto'}: esperaba ${JSON.stringify(b)} y vino ${JSON.stringify(a)}`); };
const cierto = (v, msg) => { if (!v) throw new Error(msg || 'esperaba verdadero'); };
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

// ── Supabase de mentira: /auth/v1/user y /rest/v1/offers con un RLS simplificado ──
const CLIENTE = 'aaaaaaaa-0000-0000-0000-000000000001';
const OTRO = 'bbbbbbbb-0000-0000-0000-000000000002';
const TECNICO = 'cccccccc-0000-0000-0000-000000000003';
const TOKENS = { 'token-cliente': CLIENTE, 'token-otro': OTRO };
const ofertas = new Map();
let ofertaSiguiente = 1;
function nuevaOferta({ precio = 150, estado = 'aceptada', cliente = CLIENTE } = {}) {
  const id = ofertaSiguiente++;
  ofertas.set(id, { id, price: precio, status: estado, request_id: 100 + id, technician_id: TECNICO, service_requests: { client_id: cliente, category: 'Plomería' } });
  return id;
}
function iniciarSupabaseFalso() {
  const s = http.createServer((req, res) => {
    const json = (st, b) => { res.writeHead(st, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(b)); };
    if (!req.headers.apikey) return json(401, { message: 'No API key found in request' });
    const usuario = TOKENS[String(req.headers.authorization || '').replace(/^Bearer /, '')];
    const u = new URL(req.url, 'http://x');
    if (u.pathname === '/auth/v1/user') return usuario ? json(200, { id: usuario }) : json(401, { msg: 'invalid JWT' });
    if (!usuario) return json(401, { message: 'JWT expired' });
    if (u.pathname === '/rest/v1/offers') {
      const id = Number(String(u.searchParams.get('id') || '').replace('eq.', ''));
      const o = ofertas.get(id);
      // RLS: el dueño de la solicitud o el técnico de la oferta
      const ve = o && (o.service_requests.client_id === usuario || o.technician_id === usuario);
      return json(200, ve ? [o] : []);
    }
    return json(404, {});
  });
  return new Promise((r) => s.listen(0, '127.0.0.1', () => r({ url: `http://127.0.0.1:${s.address().port}`, cerrar: () => new Promise((c) => s.close(c)) })));
}

(async () => {
  const falso = await iniciarBancoFalso();
  const supa = await iniciarSupabaseFalso();
  const d = falso.datos;
  const banco = new BancoEconomico({ url: falso.url, usuario: d.usuario, clave: d.clave, llaveAes: d.llave, cuenta: d.cuenta, prefijo: 'AY' });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pagos-arreglaya-'));
  const pagados = [];
  let n = 0;
  async function servidor(extra = {}) {
    return iniciarServidor({
      banco, archivo: path.join(dir, `cobros-${n++}.json`), puerto: 0, host: '127.0.0.1',
      supabaseUrl: supa.url, supabaseKey: 'sb_publishable_prueba', montoPrueba: 1, revisarCadaMs: 0,
      alPagar: async (c) => { pagados.push(c.id); }, ...extra,
    });
  }
  const s = await servidor();
  const base = `http://127.0.0.1:${s.puerto}`;
  const pedir = async (metodo, ruta, { token = 'token-cliente', cuerpo, url = base, headers = {} } = {}) => {
    const r = await fetch(url + ruta, {
      method: metodo,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
      body: cuerpo ? JSON.stringify(cuerpo) : undefined,
    });
    return { status: r.status, cuerpo: await r.json() };
  };

  console.log('Permisos');
  const oferta = nuevaOferta();
  await prueba('sin iniciar sesión: 401', async () => igual((await pedir('POST', '/api/pagos', { token: '', cuerpo: { ofertaId: oferta } })).status, 401));
  await prueba('token vencido o falso: 401 con mensaje claro', async () => {
    const r = await pedir('POST', '/api/pagos', { token: 'token-trucho', cuerpo: { ofertaId: oferta } });
    igual(r.status, 401);
    cierto(/sesión venció/.test(r.cuerpo.error), r.cuerpo.error);
  });
  await prueba('la oferta de otro cliente no se puede pagar: 404', async () => igual((await pedir('POST', '/api/pagos', { token: 'token-otro', cuerpo: { ofertaId: oferta } })).status, 404));
  await prueba('una oferta todavía pendiente no se puede pagar: 409', async () => igual((await pedir('POST', '/api/pagos', { cuerpo: { ofertaId: nuevaOferta({ estado: 'pendiente' }) } })).status, 409));
  await prueba('sin oferta: 400', async () => igual((await pedir('POST', '/api/pagos', { cuerpo: {} })).status, 400));

  console.log('Cobro');
  let cobro;
  await prueba('genera el QR por el monto de prueba y muestra el precio real aparte', async () => {
    const r = await pedir('POST', '/api/pagos', { cuerpo: { ofertaId: oferta } });
    igual(r.status, 200, JSON.stringify(r.cuerpo));
    cobro = r.cuerpo;
    igual(cobro.estado, 'pendiente');
    igual(cobro.monto, 1);
    igual(cobro.precioOferta, 150);
    igual(cobro.montoPrueba, true);
    cierto(cobro.imagen && cobro.imagen.length > 10, 'falta la imagen del QR');
    cierto(new Date(cobro.venceEn) > new Date(), 'venceEn');
  });
  await prueba('pedir de nuevo mientras está vigente devuelve el MISMO QR (no hay dos pagables)', async () => {
    const r = await pedir('POST', '/api/pagos', { cuerpo: { ofertaId: oferta } });
    igual(r.cuerpo.id, cobro.id);
    igual(s.almacen.deOferta(oferta).length, 1, 'cobros de la oferta');
  });
  await prueba('dos toques a la vez en otra oferta generan un solo QR', async () => {
    const o = nuevaOferta();
    const [a, b] = await Promise.all([pedir('POST', '/api/pagos', { cuerpo: { ofertaId: o } }), pedir('POST', '/api/pagos', { cuerpo: { ofertaId: o } })]);
    igual(a.cuerpo.id, b.cuerpo.id);
    igual(s.almacen.deOferta(o).length, 1);
  });
  await prueba('otro usuario no puede consultar el cobro: 404', async () => igual((await pedir('GET', `/api/pagos/${cobro.id}`, { token: 'token-otro' })).status, 404));
  await prueba('antes de pagar, la consulta dice pendiente y no manda la imagen otra vez', async () => {
    const r = await pedir('GET', `/api/pagos/${cobro.id}`);
    igual(r.cuerpo.estado, 'pendiente');
    igual(r.cuerpo.imagen, undefined);
  });
  await prueba('al pagar, la pantalla se entera: pagado por «pantalla»', async () => {
    falso.pagar(s.almacen.buscar(cobro.id).qrId);
    await dormir(3100); // la consulta al banco se limita a una cada 3 s
    const r = await pedir('GET', `/api/pagos/${cobro.id}`);
    igual(r.cuerpo.estado, 'pagado');
    igual(r.cuerpo.confirmadoPor, 'pantalla');
    igual(r.cuerpo.pago.monto, 1);
  });
  await prueba('una oferta pagada no se vuelve a cobrar', async () => {
    const r = await pedir('POST', '/api/pagos', { cuerpo: { ofertaId: oferta } });
    igual(r.cuerpo.estado, 'pagado');
    igual(r.cuerpo.id, cobro.id);
    igual(s.almacen.deOferta(oferta).length, 1);
  });
  await prueba('la tarjeta de la oferta ve «pagado»', async () => igual((await pedir('GET', `/api/pagos/oferta/${oferta}`)).cuerpo.estado, 'pagado'));
  await prueba('una oferta sin cobro dice «sin_cobro»', async () => igual((await pedir('GET', `/api/pagos/oferta/${nuevaOferta()}`)).cuerpo.estado, 'sin_cobro'));

  console.log('Los otros dos caminos');
  await prueba('revisión de cada minuto: confirma un pago aunque la app no pregunte', async () => {
    const r = await pedir('POST', '/api/pagos', { cuerpo: { ofertaId: nuevaOferta() } });
    falso.pagar(s.almacen.buscar(r.cuerpo.id).qrId);
    const rev = await s.revisar();
    igual(rev.pagados, 1);
    igual(s.almacen.buscar(r.cuerpo.id).confirmadoPor, 'revision');
  });
  await prueba('aviso del banco: confirma, pero solo después de preguntarle al banco', async () => {
    const r = await pedir('POST', '/api/pagos', { cuerpo: { ofertaId: nuevaOferta() } });
    const qrId = s.almacen.buscar(r.cuerpo.id).qrId;
    // Aviso falso: el QR existe pero no está pagado → se contesta bien y no se marca nada
    let a = await pedir('POST', '/aviso-banco', { token: '', cuerpo: { payment: { qrId, amount: 1 } } });
    igual(a.cuerpo.responseCode, 0);
    igual(s.almacen.buscar(r.cuerpo.id).estado, 'pendiente', 'un aviso falso no debe marcar pagado');
    falso.pagar(qrId);
    a = await pedir('POST', '/aviso-banco', { token: '', cuerpo: { payment: { qrId, amount: 1 } } });
    igual(a.cuerpo.responseCode, 0);
    igual(s.almacen.buscar(r.cuerpo.id).confirmadoPor, 'aviso');
  });
  await prueba('cada cobro se entrega UNA sola vez aunque lo confirmen varios caminos', async () => {
    const r = await pedir('POST', '/api/pagos', { cuerpo: { ofertaId: nuevaOferta() } });
    const qrId = s.almacen.buscar(r.cuerpo.id).qrId;
    falso.pagar(qrId);
    await Promise.all([s.revisar(), pedir('POST', '/aviso-banco', { token: '', cuerpo: { payment: { qrId } } }), pedir('GET', `/api/pagos/${r.cuerpo.id}`)]);
    igual(pagados.filter((x) => x === r.cuerpo.id).length, 1);
  });
  await prueba('aviso con token equivocado: 401', async () => {
    const s2 = await servidor({ avisoToken: 'secreto-del-aviso' });
    const r = await pedir('POST', '/aviso-banco', { token: 'otro', url: `http://127.0.0.1:${s2.puerto}`, cuerpo: { payment: { qrId: '1' } } });
    igual(r.status, 401);
    await s2.cerrar();
  });

  console.log('Vencimiento');
  const corto = await servidor({ vidaMin: 0.002 }); // 120 ms
  const baseCorto = `http://127.0.0.1:${corto.puerto}`;
  await prueba('un QR sin pagar que pasó su tiempo se anula en el banco', async () => {
    const r = await pedir('POST', '/api/pagos', { url: baseCorto, cuerpo: { ofertaId: nuevaOferta() } });
    await dormir(200);
    const rev = await corto.revisar();
    igual(rev.vencidos, 1);
    igual(corto.almacen.buscar(r.cuerpo.id).estado, 'vencido');
    igual(falso.estadoDe(corto.almacen.buscar(r.cuerpo.id).qrId), 9, 'estado en el banco');
  });
  await prueba('si se pagó justo antes de vencer, NO se anula: queda pagado', async () => {
    const r = await pedir('POST', '/api/pagos', { url: baseCorto, cuerpo: { ofertaId: nuevaOferta() } });
    falso.pagar(corto.almacen.buscar(r.cuerpo.id).qrId);
    await dormir(200);
    const g = await pedir('GET', `/api/pagos/${r.cuerpo.id}`, { url: baseCorto });
    igual(g.cuerpo.estado, 'pagado');
  });
  await prueba('después de vencer, «Pagar» genera un QR nuevo y el viejo queda anulado', async () => {
    const o = nuevaOferta();
    const a = await pedir('POST', '/api/pagos', { url: baseCorto, cuerpo: { ofertaId: o } });
    await dormir(200);
    const b = await pedir('POST', '/api/pagos', { url: baseCorto, cuerpo: { ofertaId: o } });
    cierto(a.cuerpo.id !== b.cuerpo.id, 'tenía que ser otro cobro');
    igual(falso.estadoDe(corto.almacen.buscar(a.cuerpo.id).qrId), 9, 'el QR viejo tiene que quedar anulado');
  });
  await corto.cerrar();

  console.log('Monto real y fallas');
  await prueba('con MONTO_PRUEBA=0 se cobra el precio de la oferta', async () => {
    const s3 = await servidor({ montoPrueba: 0 });
    const r = await pedir('POST', '/api/pagos', { url: `http://127.0.0.1:${s3.puerto}`, cuerpo: { ofertaId: nuevaOferta({ precio: 85.5 }) } });
    igual(r.cuerpo.monto, 85.5);
    igual(r.cuerpo.montoPrueba, false);
    await s3.cerrar();
  });
  await prueba('si Supabase no contesta: 502 con mensaje entendible', async () => {
    const s4 = await servidor({ supabaseUrl: 'http://127.0.0.1:1' });
    const r = await pedir('POST', '/api/pagos', { url: `http://127.0.0.1:${s4.puerto}`, cuerpo: { ofertaId: oferta } });
    igual(r.status, 502);
    cierto(/Supabase/.test(r.cuerpo.error), r.cuerpo.error);
    await s4.cerrar();
  });
  await prueba('los cobros sobreviven a un reinicio del servidor (archivo JSON)', async () => {
    const archivo = path.join(dir, 'persistente.json');
    const a = await servidor({ archivo });
    const r = await pedir('POST', '/api/pagos', { url: `http://127.0.0.1:${a.puerto}`, cuerpo: { ofertaId: nuevaOferta() } });
    await a.cerrar();
    const b = await servidor({ archivo });
    igual(b.almacen.buscar(r.cuerpo.id).estado, 'pendiente');
    await b.cerrar();
  });

  console.log('Página de prueba (sin app)');
  await prueba('desde esta PC abre la página', async () => {
    const r = await fetch(`${base}/prueba`);
    igual(r.status, 200);
    cierto((await r.text()).includes('Prueba de pago con QR'));
  });
  await prueba('genera un QR por el monto de prueba y se entera del pago', async () => {
    const info = await (await fetch(`${base}/prueba/info`)).json();
    igual(info.monto, 1);
    const c = await (await fetch(`${base}/prueba/cobro`, { method: 'POST' })).json();
    igual(c.monto, 1);
    cierto(c.imagen && c.imagen.length > 10, 'falta la imagen');
    falso.pagar(s.almacen.buscar(c.id).qrId);
    const e = await (await fetch(`${base}/prueba/cobro/${c.id}`)).json();
    igual(e.estado, 'pagado');
  });
  await prueba('con MONTO_PRUEBA=0 la página igual cobra Bs 1 (nunca un monto grande)', async () => {
    const s5 = await servidor({ montoPrueba: 0 });
    const c = await (await fetch(`http://127.0.0.1:${s5.puerto}/prueba/cobro`, { method: 'POST' })).json();
    igual(c.monto, 1);
    await s5.cerrar();
  });
  await prueba('no deja ver por la página un cobro hecho desde la app', async () => {
    igual((await fetch(`${base}/prueba/cobro/${cobro.id}`)).status, 404);
  });
  const ipRed = Object.values(os.networkInterfaces()).flat().find((i) => i && i.family === 'IPv4' && !i.internal);
  if (ipRed) {
    await prueba('desde otro equipo de la red la página se niega (403)', async () => {
      const s6 = await servidor({ host: '0.0.0.0' });
      const r1 = await fetch(`http://${ipRed.address}:${s6.puerto}/prueba`);
      const r2 = await fetch(`http://${ipRed.address}:${s6.puerto}/prueba/cobro`, { method: 'POST' });
      igual(r1.status, 403);
      igual(r2.status, 403);
      await s6.cerrar();
    });
  }

  await s.cerrar();
  await falso.cerrar();
  await supa.cerrar();
  fs.rmSync(dir, { recursive: true, force: true });
  console.log(`\n${mal ? '❌' : '✅'} ${bien} bien, ${mal} mal`);
  process.exit(mal ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
