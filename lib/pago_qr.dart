import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Dirección del servidor de pagos (carpeta `servidor-pagos/`), por ejemplo
/// `--dart-define=PAGOS_URL=http://192.168.1.50:3100`. Sin ella, el botón de pago no aparece.
///
/// La app nunca habla con el banco: las claves del Banco Económico viven solo en el servidor.
const pagosUrl = String.fromEnvironment('PAGOS_URL');

class PagoQrError implements Exception {
  const PagoQrError(this.mensaje);
  final String mensaje;

  @override
  String toString() => mensaje;
}

class Cobro {
  const Cobro({
    required this.id,
    required this.estado,
    required this.monto,
    required this.precioOferta,
    required this.montoPrueba,
    this.venceEn,
    this.confirmadoPor,
    this.pagadoPor,
    this.imagen,
  });

  factory Cobro.fromJson(Map<String, dynamic> j) {
    final imagen = j['imagen'] as String?;
    final pago = j['pago'] as Map<String, dynamic>?;
    return Cobro(
      id: j['id'] as String? ?? '',
      estado: j['estado'] as String? ?? 'sin_cobro',
      monto: (j['monto'] as num?)?.toDouble() ?? 0,
      precioOferta: (j['precioOferta'] as num?)?.toDouble() ?? 0,
      montoPrueba: j['montoPrueba'] as bool? ?? false,
      venceEn: DateTime.tryParse(j['venceEn'] as String? ?? ''),
      confirmadoPor: j['confirmadoPor'] as String?,
      pagadoPor: pago?['nombre'] as String?,
      imagen: imagen == null || imagen.isEmpty ? null : base64Decode(imagen),
    );
  }

  final String id;

  /// pendiente, pagado, vencido o sin_cobro.
  final String estado;
  final double monto;
  final double precioOferta;
  final bool montoPrueba;
  final DateTime? venceEn;
  final String? confirmadoPor;
  final String? pagadoPor;
  final Uint8List? imagen;

  bool get pagado => estado == 'pagado';
  bool get pendiente => estado == 'pendiente';
}

String bs(double monto) => 'Bs ${monto.toStringAsFixed(2)}';

/// Habla con el servidor de pagos. Cada pedido lleva el token de sesión de Supabase:
/// así el servidor sabe quién paga y que la oferta es suya.
class PagosApi {
  PagosApi({String? base, http.Client? cliente, Future<String?> Function()? token})
    : base = (base ?? pagosUrl).replaceAll(RegExp(r'/+$'), ''),
      _cliente = cliente ?? http.Client(),
      _token = token ?? _tokenDeSupabase;

  final String base;
  final http.Client _cliente;
  final Future<String?> Function() _token;

  static Future<String?> _tokenDeSupabase() async =>
      Supabase.instance.client.auth.currentSession?.accessToken;

  bool get configurado => base.isNotEmpty;

  /// Pide el QR de una oferta aceptada (o devuelve el que sigue vigente).
  Future<Cobro> crear(int ofertaId) => _pedir(
    'POST',
    '/api/pagos',
    cuerpo: {'ofertaId': ofertaId},
    espera: const Duration(seconds: 45),
  );

  /// ¿Ya se pagó?
  Future<Cobro> estado(String cobroId) => _pedir('GET', '/api/pagos/$cobroId');

  /// Estado del pago de una oferta, para la tarjeta de la oferta.
  Future<Cobro> deOferta(int ofertaId) =>
      _pedir('GET', '/api/pagos/oferta/$ofertaId');

  Future<Cobro> _pedir(
    String metodo,
    String ruta, {
    Map<String, dynamic>? cuerpo,
    Duration espera = const Duration(seconds: 20),
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const PagoQrError('Tu sesión venció. Volvé a iniciar sesión.');
    }
    final uri = Uri.parse('$base$ruta');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final http.Response r;
    try {
      r = await (metodo == 'POST'
              ? _cliente.post(uri, headers: headers, body: jsonEncode(cuerpo))
              : _cliente.get(uri, headers: headers))
          .timeout(espera);
    } on TimeoutException {
      throw const PagoQrError(
        'El servidor de pagos tardó demasiado en responder. Probá de nuevo.',
      );
    } catch (_) {
      throw const PagoQrError(
        'No se pudo conectar con el servidor de pagos. Revisá que esté prendido '
        'y que el celular esté en la misma red Wi-Fi que la PC.',
      );
    }
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw PagoQrError(
        'El servidor de pagos respondió algo raro (${r.statusCode}).',
      );
    }
    if (j is! Map<String, dynamic>) {
      throw PagoQrError(
        'El servidor de pagos respondió algo raro (${r.statusCode}).',
      );
    }
    if (r.statusCode != 200) {
      throw PagoQrError(j['error'] as String? ?? 'Error ${r.statusCode}');
    }
    return Cobro.fromJson(j);
  }
}

/// Va en la tarjeta de una oferta aceptada: «Pagar con QR», o «Pagado» si ya se pagó.
class PagoQrBoton extends StatefulWidget {
  const PagoQrBoton({super.key, required this.ofertaId, this.api});

  final int ofertaId;
  final PagosApi? api;

  @override
  State<PagoQrBoton> createState() => _PagoQrBotonState();
}

class _PagoQrBotonState extends State<PagoQrBoton> {
  late final PagosApi _api = widget.api ?? PagosApi();
  Cobro? _cobro;

  @override
  void initState() {
    super.initState();
    if (_api.configurado) _cargar();
  }

  Future<void> _cargar() async {
    try {
      final c = await _api.deOferta(widget.ofertaId);
      if (mounted) setState(() => _cobro = c);
    } on PagoQrError {
      // Sin servidor: el botón igual aparece y la pantalla de pago explica el problema.
    }
  }

  Future<void> _abrir() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PagoQrPantalla(ofertaId: widget.ofertaId, api: _api),
      ),
    );
    if (mounted) _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!_api.configurado) return const SizedBox.shrink();
    final c = _cobro;
    if (c != null && c.pagado) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Pagado con QR · ${bs(c.monto)}',
                  style: const TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _abrir,
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Pagar con QR'),
        ),
      ),
    );
  }
}

/// Muestra el QR, pregunta cada pocos segundos si ya se pagó y avisa «¡Pagado!».
class PagoQrPantalla extends StatefulWidget {
  const PagoQrPantalla({
    super.key,
    required this.ofertaId,
    this.api,
    this.cadaCuanto = const Duration(seconds: 3),
  });

  final int ofertaId;
  final PagosApi? api;
  final Duration cadaCuanto;

  @override
  State<PagoQrPantalla> createState() => _PagoQrPantallaState();
}

class _PagoQrPantallaState extends State<PagoQrPantalla>
    with WidgetsBindingObserver {
  late final PagosApi _api = widget.api ?? PagosApi();
  Cobro? _cobro;
  Uint8List? _imagen;
  String? _error;
  bool _cargando = true;
  bool _consultando = false;
  Timer? _consulta;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _generar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pararTimers();
    super.dispose();
  }

  // Al volver de la app del banco, se pregunta enseguida.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _consultar();
  }

  void _pararTimers() {
    _consulta?.cancel();
    _reloj?.cancel();
    _consulta = null;
    _reloj = null;
  }

  Future<void> _generar() async {
    _pararTimers();
    setState(() {
      _cargando = true;
      _error = null;
      _cobro = null;
      _imagen = null;
    });
    try {
      _aplicar(await _api.crear(widget.ofertaId));
    } on PagoQrError catch (e) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _error = e.mensaje;
        });
      }
    }
  }

  void _aplicar(Cobro c) {
    if (!mounted) return;
    setState(() {
      _cobro = c;
      if (c.imagen != null) _imagen = c.imagen;
      _cargando = false;
      _error = null;
    });
    if (c.pendiente) {
      _consulta ??= Timer.periodic(widget.cadaCuanto, (_) => _consultar());
      _reloj ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => mounted ? setState(() {}) : null,
      );
    } else {
      _pararTimers();
    }
  }

  Future<void> _consultar() async {
    final c = _cobro;
    if (c == null || !c.pendiente || _consultando) return;
    _consultando = true;
    try {
      _aplicar(await _api.estado(c.id));
    } on PagoQrError {
      // Se vuelve a intentar en la próxima vuelta.
    } finally {
      _consultando = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _cobro;
    return Scaffold(
      appBar: AppBar(title: const Text('Pagar con QR')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _cargando
                  ? const _Cargando()
                  : _error != null
                  ? _Error(
                      mensaje: _error!,
                      onReintentar: c == null ? _generar : _consultar,
                    )
                  : c!.pagado
                  ? _Pagado(cobro: c)
                  : c.pendiente
                  ? _Esperando(
                      cobro: c,
                      imagen: _imagen,
                      onYaPague: _consultar,
                    )
                  : _Vencido(onOtro: _generar),
            ),
          ),
        ),
      ),
    );
  }
}

class _Cargando extends StatelessWidget {
  const _Cargando();

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      SizedBox(height: 40),
      CircularProgressIndicator(),
      SizedBox(height: 16),
      Text('Generando el QR con el banco…'),
    ],
  );
}

class _Error extends StatelessWidget {
  const _Error({required this.mensaje, required this.onReintentar});

  final String mensaje;
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(
        Icons.error_outline,
        size: 56,
        color: Theme.of(context).colorScheme.error,
      ),
      const SizedBox(height: 12),
      Text(mensaje, textAlign: TextAlign.center),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: onReintentar,
        icon: const Icon(Icons.refresh),
        label: const Text('Reintentar'),
      ),
    ],
  );
}

class _Esperando extends StatelessWidget {
  const _Esperando({
    required this.cobro,
    required this.imagen,
    required this.onYaPague,
  });

  final Cobro cobro;
  final Uint8List? imagen;
  final VoidCallback onYaPague;

  String _quedan() {
    final vence = cobro.venceEn;
    if (vence == null) return '';
    final s = vence.difference(DateTime.now()).inSeconds;
    if (s <= 0) return 'Venciendo…';
    return 'Vence en ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Column(
      children: [
        Text(
          'Escaneá este QR con la app de tu banco',
          textAlign: TextAlign.center,
          style: tema.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          bs(cobro.monto),
          style: tema.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: const Color(0xFF075E54),
          ),
        ),
        if (cobro.montoPrueba)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Modo prueba: se cobra ${bs(cobro.monto)} '
              '(la oferta es ${bs(cobro.precioOferta)}).',
              textAlign: TextAlign.center,
            ),
          ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFDDE5E4)),
          ),
          child: imagen == null
              ? const SizedBox(
                  width: 260,
                  height: 260,
                  child: Center(child: Text('QR no disponible')),
                )
              : Image.memory(
                  imagen!,
                  key: const Key('imagen-qr'),
                  width: 260,
                  height: 260,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.none,
                ),
        ),
        const SizedBox(height: 16),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('Esperando el pago…'),
          ],
        ),
        const SizedBox(height: 4),
        Text(_quedan(), style: tema.textTheme.bodySmall),
        const SizedBox(height: 16),
        Text(
          '¿Pagás desde este mismo celular? Sacá una captura de pantalla y '
          'subila en la app de tu banco (Pagar con QR → desde la galería).',
          textAlign: TextAlign.center,
          style: tema.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: onYaPague, child: const Text('Ya pagué')),
      ],
    );
  }
}

class _Pagado extends StatelessWidget {
  const _Pagado({required this.cobro});

  final Cobro cobro;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Column(
      children: [
        const Icon(Icons.check_circle, size: 96, color: Colors.green),
        const SizedBox(height: 12),
        Text(
          '¡Pagado!',
          style: tema.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: Colors.green,
          ),
        ),
        const SizedBox(height: 8),
        Text(bs(cobro.monto), style: tema.textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'El Banco Económico confirmó el pago.',
          textAlign: TextAlign.center,
        ),
        if (cobro.pagadoPor != null && cobro.pagadoPor!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Pagó: ${cobro.pagadoPor}',
              style: tema.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Listo'),
        ),
      ],
    );
  }
}

class _Vencido extends StatelessWidget {
  const _Vencido({required this.onOtro});

  final VoidCallback onOtro;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Icon(Icons.timer_off_outlined, size: 56, color: Colors.grey),
      const SizedBox(height: 12),
      Text(
        'El QR venció sin pagarse',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      const Text(
        'Lo anulamos en el banco: ya nadie lo puede pagar.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: onOtro,
        icon: const Icon(Icons.qr_code_2),
        label: const Text('Generar otro QR'),
      ),
    ],
  );
}
