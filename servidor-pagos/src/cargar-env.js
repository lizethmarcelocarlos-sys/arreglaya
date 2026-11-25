'use strict';
// Lee un archivo .env sencillo (CLAVE=valor por línea) sin instalar nada. No pisa variables que ya existan.
const fs = require('fs');

function cargarEnv(archivo) {
  let texto;
  try { texto = fs.readFileSync(archivo, 'utf8'); } catch { return false; }
  for (const linea of texto.split(/\r?\n/)) {
    const m = linea.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m || linea.trim().startsWith('#')) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (process.env[m[1]] === undefined) process.env[m[1]] = v;
  }
  return true;
}

module.exports = { cargarEnv };
