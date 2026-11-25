'use strict';
/**
 * BANCO FALSO para probar sin plata y sin internet. Imita las respuestas del Banco Económico:
 * inicio de sesión (descifra la contraseña), generar QR (descifra la cuenta), estado, anular y pagados del día.
 * Además tiene botones de prueba: POST /falso/pagar/<qrId> (simula que alguien pagó) y POST /falso/vencer-sesion.
 *
 * Solo:  node pruebas/banco-falso.js   → muestra la URL y los datos falsos para poner en el .env
 */
const http = require('http');
const crypto = require('crypto');

// Datos INVENTADOS, solo para este banco falso
const DATOS_FALSOS = { usuario: 'USUARIOPRUEBA', clave: 'clave-de-prueba', llave: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345', cuenta: '1234567890' };
// PNG de 1×1 para la imagen del QR
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

function iniciarBancoFalso({ puerto = 0, datos = DATOS_FALSOS } = {}) {
  const llave = Buffer.from(datos.llave, 'utf8');
  const descifrar = (b64) => {
    const b = Buffer.from(String(b64 || ''), 'base64');
    const d = crypto.createDecipheriv('aes-256-cbc', llave, b.subarray(0, 16));
    return Buffer.concat([d.update(b.subarray(16)), d.final()]).toString('utf8');
  };
  const fechaBO = () => new Date(Date.now() - 4 * 3600000).toISOString().slice(0, 10);
  const tokens = new Map(); // token → vence (ms)
  const qrs = new Map(); // qrId → { ... }
  const stats = { sesiones: 0, llamadas: 0 };
  let siguiente = 1;

  const responder = (res, status, cuerpo) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(cuerpo)); };
  const conToken = (req) => {
    const t = String(req.headers.authorization || '').replace(/^Bearer /, '');
    return tokens.has(t) && tokens.get(t) > Date.now();
  };
  const leer = (req) => new Promise((r) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => { try { r(d ? JSON.parse(d) : {}); } catch { r(null); } }); });

  function pagar(qrId, { monto } = {}) {
    const q = qrs.get(String(qrId));
    if (!q || q.estado !== 0) return false;
    q.estado = 1;
    const ahora = new Date(Date.now() - 4 * 3600000).toISOString();
    q.pago = {
      qrId: q.qrId, transactionId: q.transactionId, paymentDate: `${ahora.slice(0, 10)}T00:00:00`, paymentTime: ahora.slice(11, 19),
      currency: 'BOB', amount: monto ?? q.amount, senderBankCode: '1016', senderName: 'CLIENTE DE PRUEBA', senderDocumentId: '0', senderAccount: '0000', description: q.description,
    };
    q.fechaPago = fechaBO();
    return true;
  }

  const servidor = http.createServer(async (req, res) => {
    stats.llamadas++;
    const ruta = new URL(req.url, 'http://x').pathname.replace(/^\/ApiGateway/, '');
    // ── Botones de prueba ──
    let m = ruta.match(/^\/falso\/pagar\/(\d+)$/);
    if (req.method === 'POST' && m) return responder(res, 200, { ok: pagar(m[1]) });
    if (req.method === 'POST' && ruta === '/falso/vencer-sesion') { tokens.clear(); return responder(res, 200, { ok: true }); }

    // ── API del banco ──
    if (req.method === 'POST' && ruta === '/api/authentication/authenticate') {
      const b = await leer(req);
      if (!b || b.userName !== datos.usuario) return responder(res, 200, { token: null, responseCode: 1, message: 'Usuario no habilitado para uso de apis' });
      let clave = '';
      try { clave = descifrar(b.password); } catch { /* cifrado mal */ }
      if (clave !== datos.clave) return responder(res, 200, { token: null, responseCode: 2, message: 'Credenciales incorrectas' });
      stats.sesiones++;
      const exp = Math.floor(Date.now() / 1000) + 30 * 60;
      const token = ['{"alg":"HS256"}', JSON.stringify({ sub: datos.usuario, exp }), crypto.randomBytes(8).toString('hex')]
        .map((x) => Buffer.from(x).toString('base64url')).join('.');
      tokens.set(token, exp * 1000);
      return responder(res, 200, { token, responseCode: 0, message: '' });
    }
    if (!conToken(req)) return responder(res, 401, { message: 'Unauthorized' });

    if (req.method === 'POST' && ruta === '/api/qrsimple/generateQR') {
      const b = await leer(req);
      let cuenta = '';
      try { cuenta = descifrar(b && b.accountCredit); } catch { /* cifrado mal */ }
      if (cuenta !== datos.cuenta) return responder(res, 200, { responseCode: 3, message: 'Cuenta inválida' });
      if (!b.transactionId || String(b.transactionId).length > 30) return responder(res, 200, { responseCode: 4, message: 'transactionId inválido' });
      if (b.currency !== 'BOB' || !(b.amount > 0)) return responder(res, 200, { responseCode: 5, message: 'Monto o moneda inválidos' });
      if (String(b.description || '').length > 100 || !/^\d{4}-\d{2}-\d{2}$/.test(String(b.dueDate))) return responder(res, 200, { responseCode: 6, message: 'Datos inválidos' });
      const qrId = `2611${String(Date.now()).slice(-10)}${String(siguiente++).padStart(6, '0')}`;
      qrs.set(qrId, { qrId, transactionId: b.transactionId, amount: b.amount, description: b.description, estado: 0, pago: null });
      return responder(res, 200, { qrId, qrImage: PNG, responseCode: 0, message: '' });
    }
    m = ruta.match(/^\/api\/qrsimple\/v2\/statusQR\/(.+)$/);
    if (req.method === 'GET' && m) {
      const q = qrs.get(decodeURIComponent(m[1]));
      if (!q) return responder(res, 200, { responseCode: 7, message: 'QR no encontrado' });
      return responder(res, 200, { responseCode: 0, message: '', statusQrCode: q.estado, payment: q.pago ? [q.pago] : [] });
    }
    if (req.method === 'DELETE' && ruta === '/api/qrsimple/cancelQR') {
      const b = await leer(req);
      const q = qrs.get(String(b && b.qrId));
      if (!q) return responder(res, 200, { responseCode: 7, message: 'QR no encontrado' });
      if (q.estado !== 0) return responder(res, 200, { responseCode: 8, message: 'El QR no se puede anular' });
      q.estado = 9;
      return responder(res, 200, { responseCode: 0, message: '' });
    }
    m = ruta.match(/^\/api\/qrsimple\/v2\/paidQR\/(\d{8})$/);
    if (req.method === 'GET' && m) {
      const f = `${m[1].slice(0, 4)}-${m[1].slice(4, 6)}-${m[1].slice(6)}`;
      return responder(res, 200, { responseCode: 0, message: '', paymentList: [...qrs.values()].filter((q) => q.estado === 1 && q.fechaPago === f).map((q) => q.pago) });
    }
    return responder(res, 404, { message: 'No existe' });
  });

  return new Promise((resolver) => {
    servidor.listen(puerto, '127.0.0.1', () => {
      const url = `http://127.0.0.1:${servidor.address().port}/ApiGateway/`;
      resolver({
        url, datos, stats, pagar,
        estadoDe: (qrId) => (qrs.get(String(qrId)) || {}).estado,
        vencerSesion: () => tokens.clear(),
        cerrar: () => new Promise((r) => servidor.close(() => r())),
      });
    });
  });
}

module.exports = { iniciarBancoFalso, DATOS_FALSOS };

if (require.main === module) {
  iniciarBancoFalso({ puerto: Number(process.env.PUERTO_BANCO) || 4700 }).then((b) => {
    console.log(`Banco FALSO en ${b.url}\nPara usarlo, poné en el .env:`);
    console.log(`  BANECO_URL=${b.url}\n  BANECO_USUARIO=${b.datos.usuario}\n  BANECO_CLAVE=${b.datos.clave}\n  BANECO_LLAVE_AES=${b.datos.llave}\n  BANECO_CUENTA=${b.datos.cuenta}`);
    console.log('Para simular un pago:  curl -X POST ' + b.url.replace('/ApiGateway/', '') + '/falso/pagar/<qrId>');
  });
}
