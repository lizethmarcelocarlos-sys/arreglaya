'use strict';
/**
 * Conector del QR del Banco Económico («API Market · QR Simple», manual v1.3.0).
 * Sin dependencias: Node.js 18 o más nuevo (usa fetch y crypto que ya trae Node).
 *
 * Cifrado (comprobado contra el banco real): AES-256-CBC, la llave son los 32 caracteres tal cual,
 * un IV aleatorio de 16 bytes va DELANTE del texto cifrado, y todo se manda en base64.
 * Se cifran la contraseña (al iniciar sesión) y el número de cuenta (al generar el QR).
 */
const crypto = require('crypto');

const URL_PRODUCCION = 'https://apimkt.baneco.com.bo/ApiGateway/';
const URL_PRUEBAS = 'https://apimktdesa.baneco.com.bo/ApiGateway/';

/** Estados de un QR según el banco. */
const ESTADO = Object.freeze({ PENDIENTE: 0, PAGADO: 1, ANULADO: 9 });

class ErrorBanco extends Error {
  constructor(mensaje, { codigo = null, status = null } = {}) {
    super(mensaje);
    this.name = 'ErrorBanco';
    this.codigo = codigo; // responseCode del banco, si lo mandó
    this.status = status; // código HTTP, si hubo respuesta
  }
}

/** Fecha de Bolivia (UTC-4) en formato yyyy-MM-dd, corrida N días. */
function fechaBolivia(dias = 0, ahora = Date.now()) {
  return new Date(ahora - 4 * 3600000 + dias * 86400000).toISOString().slice(0, 10);
}

// El banco acepta letras, números y signos comunes en la descripción (hasta 100 caracteres)
const limpiarTexto = (s) => String(s || '').replace(/[^\x20-\x7EáéíóúñÁÉÍÓÚÑüÜ]/g, '').replace(/\s+/g, ' ').trim();

class BancoEconomico {
  /**
   * @param {object} datos
   * @param {string} datos.usuario   Usuario de la API que da el banco (ojo con 0 y 5: un dígito mal da «no habilitado»).
   * @param {string} datos.clave     Contraseña de ese usuario.
   * @param {string} datos.llaveAes  Llave de cifrado de 32 caracteres que da el banco para ese usuario.
   * @param {string} datos.cuenta    Número de cuenta donde entra la plata de los QR.
   * @param {string} [datos.url]     Dirección de la API (por defecto la de producción).
   * @param {string} [datos.prefijo] Prefijo del número de transacción cuando no se pasa uno (por defecto «QR»).
   * @param {number} [datos.esperaMs] Cuánto esperar al banco en cada llamada (por defecto 20 s).
   */
  constructor({ usuario, clave, llaveAes, cuenta, url = URL_PRODUCCION, prefijo = 'QR', esperaMs = 20000 } = {}) {
    const falta = [!usuario && 'usuario', !clave && 'clave', !llaveAes && 'llaveAes', !cuenta && 'cuenta'].filter(Boolean);
    if (falta.length) throw new ErrorBanco(`Faltan datos del banco: ${falta.join(', ')}`);
    if (String(llaveAes).length !== 32) throw new ErrorBanco(`La llave AES tiene ${String(llaveAes).length} caracteres y deben ser 32`);
    this.usuario = String(usuario).trim();
    this.clave = String(clave);
    this.llave = Buffer.from(String(llaveAes), 'utf8');
    if (this.llave.length !== 32) throw new ErrorBanco('La llave AES tiene caracteres especiales: deben ser 32 letras o números');
    this.cuenta = String(cuenta).trim();
    this.url = String(url).replace(/\/?$/, '/');
    this.prefijo = String(prefijo).replace(/[^A-Za-z0-9]/g, '').slice(0, 8) || 'QR';
    this.esperaMs = esperaMs;
    this._token = '';
    this._vence = 0;
    this._sesionEnCurso = null;
  }

  // ── Cifrado ──

  /** Cifra un texto como pide el banco: base64( IV de 16 bytes + AES-256-CBC ). */
  cifrar(texto) {
    const iv = crypto.randomBytes(16);
    const c = crypto.createCipheriv('aes-256-cbc', this.llave, iv);
    return Buffer.concat([iv, c.update(String(texto), 'utf8'), c.final()]).toString('base64');
  }

  /** Lo contrario de cifrar (sirve para comprobar). */
  descifrar(base64) {
    const b = Buffer.from(String(base64), 'base64');
    if (b.length < 32) throw new ErrorBanco('Texto cifrado demasiado corto');
    const d = crypto.createDecipheriv('aes-256-cbc', this.llave, b.subarray(0, 16));
    return Buffer.concat([d.update(b.subarray(16)), d.final()]).toString('utf8');
  }

  // ── Llamadas al banco ──

  async _pedir(metodo, ruta, cuerpo, conToken, ms = this.esperaMs) {
    let r;
    try {
      r = await fetch(this.url + ruta, {
        method: metodo,
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          ...(conToken ? { Authorization: `Bearer ${this._token}` } : {}),
        },
        body: cuerpo ? JSON.stringify(cuerpo) : undefined,
        signal: AbortSignal.timeout(ms),
      });
    } catch (e) {
      const texto = e && e.name === 'TimeoutError' ? `el banco no contestó en ${Math.round(ms / 1000)} s` : (e && e.message) || 'sin conexión';
      throw new ErrorBanco(`Banco Económico: ${texto}`);
    }
    const txt = await r.text();
    let j = null;
    try { j = JSON.parse(txt); } catch { /* no es JSON */ }
    if (r.status === 401) {
      this._token = '';
      throw new ErrorBanco('Banco Económico: la sesión venció', { status: 401 });
    }
    if (!r.ok || !j) throw new ErrorBanco(`Banco Económico respondió ${r.status}: ${txt.slice(0, 200)}`, { status: r.status, codigo: j && j.responseCode });
    return j;
  }

  /** Inicia sesión (el permiso del banco dura unos 30 minutos; se renueva solo 5 minutos antes). */
  async iniciarSesion(forzar = false) {
    if (!forzar && this._token && Date.now() < this._vence) return this._token;
    // Si varias llamadas piden sesión a la vez, se inicia una sola
    if (!this._sesionEnCurso) {
      this._sesionEnCurso = (async () => {
        const j = await this._pedir('POST', 'api/authentication/authenticate', { userName: this.usuario, password: this.cifrar(this.clave) }, false);
        if (!j.token) {
          const m = j.message || 'sin mensaje';
          const ayuda = /no habilitado/i.test(m) ? ' — revisá el usuario (por ejemplo un 0 en lugar de un 5)' : '';
          throw new ErrorBanco(`El banco no aceptó el usuario (${j.responseCode}: ${m})${ayuda}`, { codigo: j.responseCode });
        }
        this._token = j.token;
        let exp = Date.now() + 30 * 60000;
        try { exp = JSON.parse(Buffer.from(j.token.split('.')[1], 'base64').toString()).exp * 1000; } catch { /* no es JWT: 30 min */ }
        this._vence = exp - 5 * 60000;
        return this._token;
      })().finally(() => { this._sesionEnCurso = null; });
    }
    return this._sesionEnCurso;
  }

  // Llama con sesión; si el banco dice que venció, inicia sesión de nuevo y reintenta una vez
  async _conSesion(metodo, ruta, cuerpo, ms) {
    await this.iniciarSesion();
    try {
      return await this._pedir(metodo, ruta, cuerpo, true, ms);
    } catch (e) {
      if (e.status !== 401) throw e;
      await this.iniciarSesion(true);
      return this._pedir(metodo, ruta, cuerpo, true, ms);
    }
  }

  // ── QR ──

  /**
   * Genera un QR por un monto exacto.
   * @param {object} p
   * @param {number} p.monto          Monto en Bs (se redondea a 2 decimales).
   * @param {string} [p.descripcion]  Lo que ve el cliente en su app (hasta 100 caracteres).
   * @param {string} [p.idTransaccion] Tu número de pedido (hasta 30 caracteres, letras y números). Si no va, se arma uno.
   * @param {string} [p.vence]        Fecha yyyy-MM-dd en que vence (por defecto mañana). El banco vence por DÍA:
   *                                  para que dure minutos, anulalo vos (ver ejemplo/servidor.js).
   * @param {boolean} [p.usoUnico]    true = se paga una sola vez (por defecto).
   * @param {boolean} [p.montoEditable] true = el cliente puede cambiar el monto (por defecto no).
   * @param {string} [p.sucursal]     Código de sucursal, si el banco te dio uno.
   * @returns {Promise<{qrId: string, imagenBase64: string, idTransaccion: string}>}
   */
  async generarQR({ monto, descripcion = 'Pago', idTransaccion, vence, usoUnico = true, montoEditable = false, sucursal } = {}) {
    const m = Math.round(Number(monto) * 100) / 100;
    if (!(m > 0)) throw new ErrorBanco('El monto tiene que ser mayor a 0');
    const tx = idTransaccion
      ? String(idTransaccion).replace(/[^A-Za-z0-9_-]/g, '')
      : `${this.prefijo}${Date.now()}${crypto.randomBytes(2).toString('hex')}`;
    if (!tx || tx.length > 30) throw new ErrorBanco('El número de transacción tiene que tener entre 1 y 30 letras o números');
    const cuerpo = {
      transactionId: tx,
      accountCredit: this.cifrar(this.cuenta),
      currency: 'BOB',
      amount: m,
      description: limpiarTexto(descripcion).slice(0, 100) || 'Pago',
      dueDate: vence || fechaBolivia(1),
      singleUse: !!usoUnico,
      modifyAmount: !!montoEditable,
    };
    if (sucursal) cuerpo.branchCode = String(sucursal);
    const j = await this._conSesion('POST', 'api/qrsimple/generateQR', cuerpo);
    if (j.responseCode !== 0 || !j.qrId || !j.qrImage) {
      throw new ErrorBanco(`El banco no generó el QR (${j.responseCode}: ${j.message || 'sin mensaje'})`, { codigo: j.responseCode });
    }
    return { qrId: String(j.qrId), imagenBase64: String(j.qrImage).replace(/^data:image\/\w+;base64,/, ''), idTransaccion: tx };
  }

  /**
   * Pregunta al banco cómo está un QR.
   * @returns {Promise<{estado: number, pagado: boolean, anulado: boolean, pago: object|null}>}
   *          estado: 0 = esperando el pago, 1 = pagado, 9 = anulado. «pago» trae monto, fecha, hora y quién pagó.
   */
  async estadoQR(qrId) {
    const j = await this._conSesion('GET', `api/qrsimple/v2/statusQR/${encodeURIComponent(String(qrId))}`, undefined, 15000);
    if (j.responseCode !== 0) throw new ErrorBanco(`El banco no informó el estado (${j.responseCode}: ${j.message || 'sin mensaje'})`, { codigo: j.responseCode });
    const estado = Number(j.statusQrCode ?? j.statusQRCode);
    const pago = (Array.isArray(j.payment) ? j.payment[0] : j.payment) || null;
    return { estado, pagado: estado === ESTADO.PAGADO, anulado: estado === ESTADO.ANULADO, pago };
  }

  /** Anula un QR para que ya no se pueda pagar. Devuelve true si el banco lo anuló. */
  async anularQR(qrId) {
    const j = await this._conSesion('DELETE', 'api/qrsimple/cancelQR', { qrId: String(qrId) }, 15000);
    return j.responseCode === 0;
  }

  /** QR pagados en una fecha (yyyy-MM-dd de Bolivia; por defecto hoy). */
  async pagadosDelDia(fecha = fechaBolivia()) {
    const j = await this._conSesion('GET', `api/qrsimple/v2/paidQR/${String(fecha).replace(/-/g, '')}`, undefined, 30000);
    if (j.responseCode !== 0) return [];
    return Array.isArray(j.paymentList) ? j.paymentList : [];
  }

  /**
   * Aviso de pago que manda el banco a tu «URL de notificación».
   * NO se confía en el aviso: se le pregunta al banco el estado del QR.
   * @param {object} cuerpo  El JSON que llegó: { payment: { qrId, transactionId, amount, ... } }
   * @returns {Promise<{qrId: string, pagado: boolean, pago: object|null}>}
   */
  async verificarAviso(cuerpo) {
    const p = (cuerpo && (cuerpo.payment || cuerpo.Payment)) || cuerpo || {};
    const qrId = String(p.qrId || '').trim();
    if (!qrId) return { qrId: '', pagado: false, pago: null };
    try {
      const { pagado, pago } = await this.estadoQR(qrId);
      return { qrId, pagado, pago };
    } catch (e) {
      // El banco contestó que ese QR no existe o no es tuyo: el aviso es falso, se ignora.
      // Si no se pudo hablar con el banco (sin código), se lanza el error para que el banco vuelva a avisar.
      if (e instanceof ErrorBanco && e.codigo !== null && e.codigo !== undefined) return { qrId, pagado: false, pago: null };
      throw e;
    }
  }
}

/** Lo que hay que contestarle al banco cuando avisa un pago. */
const respuestaAviso = (ok = true) => ({ responseCode: ok ? 0 : 1, message: ok ? '' : 'Error temporal' });

/** Crea el conector con los datos del archivo .env (BANECO_URL, BANECO_USUARIO, BANECO_CLAVE, BANECO_LLAVE_AES, BANECO_CUENTA). */
function desdeEnv(env = process.env) {
  return new BancoEconomico({
    url: env.BANECO_URL || URL_PRODUCCION,
    usuario: env.BANECO_USUARIO,
    clave: env.BANECO_CLAVE,
    llaveAes: env.BANECO_LLAVE_AES,
    cuenta: env.BANECO_CUENTA,
    prefijo: env.BANECO_PREFIJO || 'QR',
  });
}

module.exports = { BancoEconomico, ErrorBanco, ESTADO, URL_PRODUCCION, URL_PRUEBAS, fechaBolivia, respuestaAviso, desdeEnv };
