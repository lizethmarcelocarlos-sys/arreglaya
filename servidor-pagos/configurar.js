'use strict';
/**
 * Guarda los datos del Banco Económico en servidor-pagos/.env, pero SOLO si funcionan.
 * Antes de guardar los prueba: inicia sesión, genera un QR de Bs 1 y lo anula enseguida (nadie lo puede pagar).
 *
 * Uso (en una terminal):
 *   node configurar.js                              → te pide los datos sin mostrarlos
 *   node configurar.js --ssh root@IP:/ruta/.env     → los trae del .env de otra tienda por SSH (solo las líneas
 *                                                     BANECO_), sin mostrarlos. Te pide la contraseña del servidor.
 *   node configurar.js --archivo C:\ruta\.env       → lo mismo, desde un archivo .env de esta PC
 *   node configurar.js --borrar                     → borra los datos del banco del .env (al terminar la prueba)
 */
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');
const { BancoEconomico, URL_PRODUCCION } = require('./src/baneco');

const ENV = path.join(__dirname, '.env');
const MODELO = path.join(__dirname, '.env.ejemplo');
const CLAVES = ['BANECO_URL', 'BANECO_USUARIO', 'BANECO_CLAVE', 'BANECO_LLAVE_AES', 'BANECO_CUENTA'];
const arg = (n) => { const i = process.argv.indexOf(n); return i >= 0 ? process.argv[i + 1] : null; };

// ── .env ──
function leerTextoEnv(texto) {
  const o = {};
  for (const l of String(texto).split(/\r?\n/)) {
    const m = l.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (m && !l.trim().startsWith('#')) o[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
  }
  return o;
}
const leerEnv = () => (fs.existsSync(ENV) ? leerTextoEnv(fs.readFileSync(ENV, 'utf8')) : {});
function ponerEnv(cambios) {
  if (!fs.existsSync(ENV)) fs.copyFileSync(MODELO, ENV);
  const lineas = fs.readFileSync(ENV, 'utf8').replace(/\r?\n$/, '').split(/\r?\n/);
  for (const [k, v] of Object.entries(cambios)) {
    const i = lineas.findIndex((l) => new RegExp(`^\\s*${k}\\s*=`).test(l));
    if (i >= 0) lineas[i] = `${k}=${v}`; else lineas.push(`${k}=${v}`);
  }
  fs.writeFileSync(ENV, lineas.join('\n') + '\n', { mode: 0o600 });
}

// Los nombres de las tiendas World Sale (BANECO_USER…) o los de este servidor (BANECO_USUARIO…)
function datosDe(env) {
  return {
    url: env.BANECO_URL || URL_PRODUCCION,
    usuario: env.BANECO_USUARIO || env.BANECO_USER || '',
    clave: env.BANECO_CLAVE || env.BANECO_PASS || '',
    llave: env.BANECO_LLAVE_AES || env.BANECO_AES_KEY || '',
    cuenta: env.BANECO_CUENTA || env.BANECO_ACCOUNT || '',
  };
}

const SEGURO = /^[^\s'"]+$/; // sin espacios ni comillas: no rompen el .env
function revisar(d) {
  if (!d.usuario || !d.clave || !d.cuenta) return 'Faltan datos (usuario, contraseña o cuenta).';
  if (d.llave.length !== 32) return `La llave tiene ${d.llave.length} caracteres y deben ser 32.`;
  for (const [n, v] of [['usuario', d.usuario], ['contraseña', d.clave], ['llave', d.llave], ['cuenta', d.cuenta], ['dirección', d.url]]) {
    if (!SEGURO.test(v)) return `La ${n} tiene espacios o comillas.`;
  }
  return '';
}

async function probarYGuardar(d) {
  console.log('\n=== Probando con el banco ===');
  const url = d.url.replace(/\/?$/, '/');
  const banco = new BancoEconomico({ url, usuario: d.usuario, clave: d.clave, llaveAes: d.llave, cuenta: d.cuenta, prefijo: 'AY', esperaMs: 60000 });
  try {
    await banco.iniciarSesion();
  } catch (e) {
    console.log(`  ❌ No entró: ${e.message}. No se guardó nada.`);
    if (/credencial|incorrect|inv[aá]lid|no v[aá]lid/i.test(e.message)) {
      console.log('  → El banco reconoce el usuario: lo que no coincide es la contraseña o la llave.');
      console.log('    No lo pruebes muchas veces seguidas: el banco puede bloquear el usuario.');
    }
    process.exit(1);
  }
  console.log('  ✅ sesión iniciada');
  let qr;
  try {
    qr = await banco.generarQR({ monto: 1, descripcion: 'Prueba de configuracion ArreglaYa', idTransaccion: `AYCONF${Date.now()}` });
  } catch (e) {
    console.log(`  ❌ El banco no generó el QR de prueba: ${e.message}. Revisá la cuenta. No se guardó nada.`);
    process.exit(1);
  }
  const anulado = await banco.anularQR(qr.qrId).catch(() => false);
  console.log(`  ✅ QR de prueba generado y ${anulado ? 'anulado enseguida (nadie lo puede pagar)' : 'NO se pudo anular (vence mañana: no lo pagues)'}`);
  ponerEnv({ BANECO_URL: url, BANECO_USUARIO: d.usuario, BANECO_CLAVE: d.clave, BANECO_LLAVE_AES: d.llave, BANECO_CUENTA: d.cuenta });
  console.log('\n✅ Listo: datos guardados en servidor-pagos/.env (ese archivo no se sube a GitHub).');
  console.log('   Ahora prendé el servidor:  node servidor.js   y abrí  http://localhost:3100/prueba');
}

// ── Traer los datos de otro .env (por SSH o de un archivo), sin mostrarlos ──
async function importar() {
  const ssh = arg('--ssh');
  let texto;
  if (ssh) {
    const m = ssh.match(/^([^:\s]+):(\/[^\s'"]+)$/);
    if (!m) { console.log('❌ Usá:  node configurar.js --ssh root@IP:/ruta/del/.env'); process.exit(1); }
    console.log(`Leyendo los datos del banco de ${m[1]} (solo las líneas BANECO_)…`);
    // La contraseña del servidor la pide ssh directo en la terminal; de la salida no se muestra nada
    const r = spawnSync('ssh', ['-o', 'ConnectTimeout=20', m[1], `grep -E '^BANECO_' '${m[2]}'`], { stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8' });
    if (r.error) { console.log(`❌ No pude usar ssh: ${r.error.message}`); process.exit(1); }
    if (r.status === 255) { console.log('❌ No se pudo entrar al servidor por SSH. No se cambió nada.'); process.exit(1); }
    texto = r.stdout || '';
  } else {
    const archivo = arg('--archivo');
    try { texto = fs.readFileSync(archivo, 'utf8'); } catch { console.log(`❌ No pude leer ${archivo}`); process.exit(1); }
  }
  const d = datosDe(leerTextoEnv(texto));
  if (!d.usuario && !d.clave) {
    console.log('❌ En ese .env no están los datos del Banco Económico (puede que esa tienda todavía no lo tenga activado).');
    console.log('   Escribilos a mano con:  node configurar.js');
    process.exit(1);
  }
  const problema = revisar(d);
  if (problema) { console.log(`❌ ${problema} No se cambió nada.`); process.exit(1); }
  console.log(`  Encontré los datos: usuario (${d.usuario.length} caracteres), contraseña, llave (${d.llave.length}) y cuenta · banco: ${d.url}`);
  await probarYGuardar(d);
}

// ── Pedirlos a mano (con «oculto» no se ve lo que se escribe) ──
async function aMano() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: !!process.stdin.isTTY });
  let ocultar = false;
  const eco = rl._writeToOutput.bind(rl);
  rl._writeToOutput = (s) => { if (!ocultar) eco(s); };
  const cola = [];
  let espera = null;
  rl.on('line', (l) => { if (espera) { const r = espera; espera = null; r(l); } else cola.push(l); });
  rl.on('close', () => { if (espera) { console.log('\nSe cortó la entrada: no se guardó nada.'); process.exit(1); } });
  const preguntar = (q, oculto = false) => new Promise((res) => {
    process.stdout.write(q);
    ocultar = oculto;
    const tomar = (a) => { ocultar = false; if (oculto) process.stdout.write('\n'); res(a.replace(/[\u0000-\u001f\u007f\u200b-\u200d\ufeff]/g, '').trim()); };
    if (cola.length) tomar(cola.shift()); else espera = tomar;
  });

  const env = leerEnv();
  console.log('DATOS DEL BANCO ECONÓMICO PARA EL SERVIDOR DE PAGOS DE ARREGLAYA');
  console.log(env.BANECO_USUARIO ? '  (ya hay datos guardados: si los nuevos funcionan, los reemplazan)\n' : '');
  const url = (await preguntar(`Dirección del banco [Enter = ${env.BANECO_URL || URL_PRODUCCION}]: `)) || env.BANECO_URL || URL_PRODUCCION;
  const usuario = await preguntar('Usuario del banco: ');
  const clave = await preguntar('Contraseña (no se ve): ', true);
  const llave = await preguntar('Llave AES, 32 caracteres (no se ve): ', true);
  const cuenta = await preguntar('Número de cuenta para los abonos (no se ve): ', true);
  const d = { url, usuario, clave, llave, cuenta };
  const problema = revisar(d);
  if (problema) { rl.close(); console.log(`❌ ${problema} No se guardó nada.`); process.exit(1); }

  // Antes de gastar un intento con el banco (varios fallos seguidos pueden bloquear el usuario)
  const huella = (s) => `${s.length} caracteres, empieza con «${s.slice(0, 2)}» y termina con «${s.slice(-2)}»`;
  const avisoLlave = /^[0-9A-F]{32}$/.test(llave) ? ''
    : /^[0-9a-fA-F]{32}$/.test(llave) ? '\n      ⚠️ tiene minúsculas: si la del banco está en MAYÚSCULAS, escribila igual'
      : '\n      ⚠️ tiene letras fuera de 0-9 y A-F: ¿una O en vez de un 0, o una I/l en vez de un 1?';
  console.log('\nCompará con lo que te dio el banco:');
  console.log(`  · usuario:    ${usuario}`);
  console.log(`  · contraseña: ${huella(clave)}`);
  console.log(`  · llave:      ${huella(llave)}${avisoLlave}`);
  console.log(`  · cuenta:     ${huella(cuenta)}`);
  if (process.stdin.isTTY) cola.length = 0; // un Enter de más al pegar no cuenta como respuesta
  const ok = (await preguntar('\n¿Coincide todo? Escribí s y Enter para probar con el banco (otra cosa = cancelar): ')).toLowerCase();
  rl.close();
  if (!['s', 'si', 'sí'].includes(ok)) { console.log('No se probó nada con el banco ni se guardó nada.'); process.exit(0); }
  await probarYGuardar(d);
}

function borrar() {
  if (!fs.existsSync(ENV)) { console.log('No hay .env: no había nada que borrar.'); return; }
  const lineas = fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => !CLAVES.some((k) => new RegExp(`^\\s*${k}\\s*=`).test(l)));
  fs.writeFileSync(ENV, lineas.join('\n'), { mode: 0o600 });
  console.log('✅ Datos del banco borrados de servidor-pagos/.env. El servidor ya no puede cobrar hasta que los vuelvas a poner.');
}

(async () => {
  if (process.argv.includes('--borrar')) return borrar();
  if (arg('--ssh') || arg('--archivo')) return importar();
  return aMano();
})().catch((e) => { console.log('ERROR: ' + e.message); process.exit(1); });
