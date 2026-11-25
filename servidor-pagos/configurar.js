'use strict';
/**
 * Guarda los datos del Banco Económico en servidor-pagos/.env, pero SOLO si funcionan.
 * Pide los datos sin mostrarlos en pantalla, muestra una «huella» para compararlos con lo que dio el banco,
 * y recién con tu «s» los prueba: inicia sesión, genera un QR de Bs 1 y lo anula enseguida (nadie lo puede pagar).
 *
 * Uso (en una terminal, no desde un script):   node configurar.js
 */
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { BancoEconomico, URL_PRODUCCION } = require('./src/baneco');

const ENV = path.join(__dirname, '.env');
const MODELO = path.join(__dirname, '.env.ejemplo');

// ── Preguntas (con «oculto» no se ve lo que se escribe) ──
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
  const tomar = (a) => { ocultar = false; if (oculto) process.stdout.write('\n'); res(a.replace(/[\u0000-\u001f\u007f​-‍﻿]/g, '').trim()); };
  if (cola.length) tomar(cola.shift()); else espera = tomar;
});

// ── .env ──
function leerEnv() {
  const o = {};
  if (!fs.existsSync(ENV)) return o;
  for (const l of fs.readFileSync(ENV, 'utf8').split(/\r?\n/)) {
    const m = l.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (m && !l.trim().startsWith('#')) o[m[1]] = m[2].trim();
  }
  return o;
}
function ponerEnv(cambios) {
  if (!fs.existsSync(ENV)) fs.copyFileSync(MODELO, ENV);
  const lineas = fs.readFileSync(ENV, 'utf8').replace(/\r?\n$/, '').split(/\r?\n/);
  for (const [k, v] of Object.entries(cambios)) {
    const i = lineas.findIndex((l) => new RegExp(`^\\s*${k}\\s*=`).test(l));
    if (i >= 0) lineas[i] = `${k}=${v}`; else lineas.push(`${k}=${v}`);
  }
  fs.writeFileSync(ENV, lineas.join('\n') + '\n', { mode: 0o600 });
}

const huella = (s) => `${s.length} caracteres, empieza con «${s.slice(0, 2)}» y termina con «${s.slice(-2)}»`;
const SEGURO = /^[^\s'"]+$/; // sin espacios ni comillas: no rompen el .env

(async () => {
  const env = leerEnv();
  console.log('DATOS DEL BANCO ECONÓMICO PARA EL SERVIDOR DE PAGOS DE ARREGLAYA');
  console.log(env.BANECO_USUARIO ? '  (ya hay datos guardados: si los nuevos funcionan, los reemplazan)\n' : '');
  const url = ((await preguntar(`Dirección del banco [Enter = ${env.BANECO_URL || URL_PRODUCCION}]: `)) || env.BANECO_URL || URL_PRODUCCION).replace(/\/?$/, '/');
  const usuario = await preguntar('Usuario del banco: ');
  const clave = await preguntar('Contraseña (no se ve): ', true);
  const llave = await preguntar('Llave AES, 32 caracteres (no se ve): ', true);
  const cuenta = await preguntar('Número de cuenta para los abonos (no se ve): ', true);
  if (!usuario || !clave || !cuenta) { rl.close(); console.log('❌ Faltan datos. No se guardó nada.'); process.exit(1); }
  if (llave.length !== 32) { rl.close(); console.log(`❌ La llave tiene ${llave.length} caracteres y deben ser 32. No se guardó nada.`); process.exit(1); }
  for (const [n, v] of [['usuario', usuario], ['contraseña', clave], ['llave', llave], ['cuenta', cuenta], ['dirección', url]]) {
    if (!SEGURO.test(v)) { rl.close(); console.log(`❌ La ${n} tiene espacios o comillas. No se guardó nada.`); process.exit(1); }
  }

  // Antes de gastar un intento con el banco (varios fallos seguidos pueden bloquear el usuario)
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

  console.log('\n=== Probando con el banco ===');
  const banco = new BancoEconomico({ url, usuario, clave, llaveAes: llave, cuenta, prefijo: 'AY', esperaMs: 60000 });
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

  ponerEnv({ BANECO_URL: url, BANECO_USUARIO: usuario, BANECO_CLAVE: clave, BANECO_LLAVE_AES: llave, BANECO_CUENTA: cuenta });
  console.log('\n✅ Listo: datos guardados en servidor-pagos/.env (ese archivo no se sube a GitHub).');
  console.log('   Ahora prendé el servidor:  node servidor.js');
})().catch((e) => { console.log('ERROR: ' + e.message); process.exit(1); });
