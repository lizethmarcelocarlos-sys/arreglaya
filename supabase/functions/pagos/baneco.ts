// Conector del QR del Banco Económico («API Market · QR Simple», manual v1.3.0).
// Es la misma lógica de servidor-pagos/src/baneco.js (la que ya cobró plata real), en TypeScript.
// Corre igual en Supabase Edge Functions (Deno) y en Node 22+ (para las pruebas).
//
// Cifrado: AES-256-CBC, la llave son los 32 caracteres tal cual, un IV aleatorio de 16 bytes va
// DELANTE del texto cifrado y todo se manda en base64. Se cifran la contraseña y la cuenta.
import { Buffer } from 'node:buffer';
import { createCipheriv, randomBytes } from 'node:crypto';

export const URL_PRODUCCION = 'https://apimkt.baneco.com.bo/ApiGateway/';

export class ErrorBanco extends Error {
  codigo: number | null;
  status: number | null;
  constructor(mensaje: string, codigo: number | null = null, status: number | null = null) {
    super(mensaje);
    this.name = 'ErrorBanco';
    this.codigo = codigo; // responseCode del banco, si lo mandó
    this.status = status; // código HTTP, si hubo respuesta
  }
}

export type PagoBanco = {
  qrId?: string;
  transactionId?: string;
  amount?: number;
  paymentDate?: string;
  paymentTime?: string;
  senderName?: string;
  senderBankCode?: string;
};

export type EstadoQr = { estado: number; pagado: boolean; anulado: boolean; pago: PagoBanco | null };

/** Fecha de Bolivia (UTC-4) en formato yyyy-MM-dd, corrida N días. */
export function fechaBolivia(dias = 0, ahora = Date.now()): string {
  return new Date(ahora - 4 * 3600000 + dias * 86400000).toISOString().slice(0, 10);
}

const limpiarTexto = (s: unknown) =>
  String(s ?? '').replace(/[^\x20-\x7EáéíóúñÁÉÍÓÚÑüÜ]/g, '').replace(/\s+/g, ' ').trim();

export type DatosBanco = {
  usuario: string;
  clave: string;
  llaveAes: string;
  cuenta: string;
  url?: string;
  esperaMs?: number;
};

export class BancoEconomico {
  url: string;
  usuario: string;
  clave: string;
  cuenta: string;
  llave: Buffer;
  esperaMs: number;
  token = '';
  vence = 0;
  sesionEnCurso: Promise<string> | null = null;

  constructor(d: DatosBanco) {
    const falta = [!d.usuario && 'usuario', !d.clave && 'clave', !d.llaveAes && 'llaveAes', !d.cuenta && 'cuenta'].filter(Boolean);
    if (falta.length) throw new ErrorBanco(`Faltan datos del banco: ${falta.join(', ')}`);
    this.llave = Buffer.from(String(d.llaveAes), 'utf8');
    if (this.llave.length !== 32) throw new ErrorBanco(`La llave AES tiene ${this.llave.length} caracteres y deben ser 32`);
    this.usuario = String(d.usuario).trim();
    this.clave = String(d.clave);
    this.cuenta = String(d.cuenta).trim();
    this.url = String(d.url || URL_PRODUCCION).replace(/\/?$/, '/');
    this.esperaMs = d.esperaMs ?? 20000;
  }

  cifrar(texto: string): string {
    const iv = randomBytes(16);
    const c = createCipheriv('aes-256-cbc', this.llave, iv);
    return Buffer.concat([iv, c.update(String(texto), 'utf8'), c.final()]).toString('base64');
  }

  async pedir(metodo: string, ruta: string, cuerpo: unknown, conToken: boolean, ms = this.esperaMs): Promise<Record<string, any>> {
    let r: Response;
    try {
      r = await fetch(this.url + ruta, {
        method: metodo,
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          ...(conToken ? { Authorization: `Bearer ${this.token}` } : {}),
        },
        body: cuerpo ? JSON.stringify(cuerpo) : undefined,
        signal: AbortSignal.timeout(ms),
      });
    } catch (e) {
      const err = e as Error;
      const texto = err && err.name === 'TimeoutError' ? `el banco no contestó en ${Math.round(ms / 1000)} s` : (err && err.message) || 'sin conexión';
      throw new ErrorBanco(`Banco Económico: ${texto}`);
    }
    const txt = await r.text();
    let j: Record<string, any> | null = null;
    try { j = JSON.parse(txt); } catch { /* no es JSON */ }
    if (r.status === 401) {
      this.token = '';
      throw new ErrorBanco('Banco Económico: la sesión venció', null, 401);
    }
    if (!r.ok || !j) throw new ErrorBanco(`Banco Económico respondió ${r.status}: ${txt.slice(0, 200)}`, j?.responseCode ?? null, r.status);
    return j;
  }

  /** Inicia sesión (el permiso dura unos 30 minutos; se renueva solo 5 minutos antes). */
  iniciarSesion(forzar = false): Promise<string> {
    if (!forzar && this.token && Date.now() < this.vence) return Promise.resolve(this.token);
    if (!this.sesionEnCurso) {
      this.sesionEnCurso = (async () => {
        const j = await this.pedir('POST', 'api/authentication/authenticate', { userName: this.usuario, password: this.cifrar(this.clave) }, false);
        if (!j.token) {
          const m = j.message || 'sin mensaje';
          const ayuda = /no habilitado/i.test(m) ? ' — revisa el usuario (por ejemplo un 0 en lugar de un 5)' : '';
          throw new ErrorBanco(`El banco no aceptó el usuario (${j.responseCode}: ${m})${ayuda}`, j.responseCode ?? null);
        }
        this.token = j.token;
        let exp = Date.now() + 30 * 60000;
        try { exp = JSON.parse(Buffer.from(String(j.token).split('.')[1], 'base64').toString()).exp * 1000; } catch { /* no es JWT */ }
        this.vence = exp - 5 * 60000;
        return this.token;
      })().finally(() => { this.sesionEnCurso = null; });
    }
    return this.sesionEnCurso;
  }

  async conSesion(metodo: string, ruta: string, cuerpo?: unknown, ms?: number): Promise<Record<string, any>> {
    await this.iniciarSesion();
    try {
      return await this.pedir(metodo, ruta, cuerpo, true, ms);
    } catch (e) {
      if ((e as ErrorBanco).status !== 401) throw e;
      await this.iniciarSesion(true);
      return this.pedir(metodo, ruta, cuerpo, true, ms);
    }
  }

  async generarQR(p: { monto: number; descripcion?: string; idTransaccion: string }): Promise<{ qrId: string; imagenBase64: string }> {
    const m = Math.round(Number(p.monto) * 100) / 100;
    if (!(m > 0)) throw new ErrorBanco('El monto tiene que ser mayor a 0');
    const tx = String(p.idTransaccion).replace(/[^A-Za-z0-9_-]/g, '');
    if (!tx || tx.length > 30) throw new ErrorBanco('El número de transacción tiene que tener entre 1 y 30 letras o números');
    const j = await this.conSesion('POST', 'api/qrsimple/generateQR', {
      transactionId: tx,
      accountCredit: this.cifrar(this.cuenta),
      currency: 'BOB',
      amount: m,
      description: limpiarTexto(p.descripcion).slice(0, 100) || 'Pago',
      dueDate: fechaBolivia(1),
      singleUse: true,
      modifyAmount: false,
    });
    if (j.responseCode !== 0 || !j.qrId || !j.qrImage) {
      throw new ErrorBanco(`El banco no generó el QR (${j.responseCode}: ${j.message || 'sin mensaje'})`, j.responseCode ?? null);
    }
    return { qrId: String(j.qrId), imagenBase64: String(j.qrImage).replace(/^data:image\/\w+;base64,/, '') };
  }

  /** Estado de un QR: 0 = esperando el pago, 1 = pagado, 9 = anulado. */
  async estadoQR(qrId: string): Promise<EstadoQr> {
    const j = await this.conSesion('GET', `api/qrsimple/v2/statusQR/${encodeURIComponent(String(qrId))}`, undefined, 15000);
    if (j.responseCode !== 0) throw new ErrorBanco(`El banco no informó el estado (${j.responseCode}: ${j.message || 'sin mensaje'})`, j.responseCode ?? null);
    const estado = Number(j.statusQrCode ?? j.statusQRCode);
    const pago = ((Array.isArray(j.payment) ? j.payment[0] : j.payment) || null) as PagoBanco | null;
    return { estado, pagado: estado === 1, anulado: estado === 9, pago };
  }

  async anularQR(qrId: string): Promise<boolean> {
    const j = await this.conSesion('DELETE', 'api/qrsimple/cancelQR', { qrId: String(qrId) }, 15000);
    return j.responseCode === 0;
  }

  async pagadosDelDia(fecha = fechaBolivia()): Promise<PagoBanco[]> {
    const j = await this.conSesion('GET', `api/qrsimple/v2/paidQR/${String(fecha).replace(/-/g, '')}`, undefined, 30000);
    if (j.responseCode !== 0) return [];
    return Array.isArray(j.paymentList) ? j.paymentList : [];
  }
}
