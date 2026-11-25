import 'dart:convert';

import 'package:arreglaya/pago_qr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// PNG de 1×1 (lo que en la realidad es la imagen del QR que manda el banco)
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Map<String, dynamic> _cobro(String estado, {bool imagen = false}) => {
  'id': 'AYPRUEBA1',
  'estado': estado,
  'monto': 1,
  'precioOferta': 150,
  'montoPrueba': true,
  'ofertaId': 7,
  'venceEn': DateTime.now()
      .add(const Duration(minutes: 10))
      .toUtc()
      .toIso8601String(),
  'confirmadoPor': estado == 'pagado' ? 'pantalla' : null,
  'pago': estado == 'pagado' ? {'nombre': 'CLIENTE DE PRUEBA'} : null,
  if (imagen) 'imagen': _png,
};

http.Response _json(Object cuerpo, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(cuerpo)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

PagosApi _api(MockClient cliente) => PagosApi(
  base: 'http://pagos.prueba:3100',
  cliente: cliente,
  token: () async => 'token-de-prueba',
);

Widget _pantalla(PagosApi api) => MaterialApp(
  home: PagoQrPantalla(
    ofertaId: 7,
    api: api,
    cadaCuanto: const Duration(seconds: 1),
  ),
);

void main() {
  testWidgets('muestra el QR y pasa a «¡Pagado!» cuando el banco confirma', (
    tester,
  ) async {
    var consultas = 0;
    final pedidos = <http.Request>[];
    final api = _api(
      MockClient((r) async {
        pedidos.add(r);
        if (r.method == 'POST') return _json(_cobro('pendiente', imagen: true));
        consultas++;
        return _json(_cobro(consultas >= 2 ? 'pagado' : 'pendiente'));
      }),
    );
    await tester.pumpWidget(_pantalla(api));
    await tester.pump();

    expect(find.text('Escaneá este QR con la app de tu banco'), findsOneWidget);
    expect(find.byKey(const Key('imagen-qr')), findsOneWidget);
    expect(find.text('Bs 1.00'), findsOneWidget);
    expect(find.textContaining('Modo prueba'), findsOneWidget);
    expect(find.textContaining('Bs 150.00'), findsOneWidget);

    // El pedido lleva la sesión y la oferta; el monto lo decide el servidor
    expect(pedidos.first.headers['Authorization'], 'Bearer token-de-prueba');
    expect(jsonDecode(pedidos.first.body), {'ofertaId': 7});

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Esperando el pago…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('¡Pagado!'), findsOneWidget);
    expect(find.text('Pagó: CLIENTE DE PRUEBA'), findsOneWidget);

    // Ya pagado deja de preguntar
    final antes = consultas;
    await tester.pump(const Duration(seconds: 5));
    expect(consultas, antes);
  });

  testWidgets('sin conexión con el servidor muestra el problema y reintenta', (
    tester,
  ) async {
    var intentos = 0;
    final api = _api(
      MockClient((r) async {
        intentos++;
        if (intentos == 1) throw http.ClientException('sin red');
        return _json(_cobro('pendiente', imagen: true));
      }),
    );
    await tester.pumpWidget(_pantalla(api));
    await tester.pump();
    expect(
      find.textContaining('No se pudo conectar con el servidor de pagos'),
      findsOneWidget,
    );

    await tester.tap(find.text('Reintentar'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('imagen-qr')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('muestra el error que manda el servidor (oferta no aceptada)', (
    tester,
  ) async {
    final api = _api(
      MockClient(
        (r) async => _json({
          'error': 'Solo se puede pagar una oferta aceptada.',
        }, 409),
      ),
    );
    await tester.pumpWidget(_pantalla(api));
    await tester.pump();
    expect(
      find.text('Solo se puede pagar una oferta aceptada.'),
      findsOneWidget,
    );
  });

  testWidgets('si el QR vence, ofrece generar otro', (tester) async {
    var posts = 0;
    final api = _api(
      MockClient((r) async {
        if (r.method == 'POST') {
          posts++;
          return _json(_cobro('pendiente', imagen: true));
        }
        return _json(_cobro('vencido'));
      }),
    );
    await tester.pumpWidget(_pantalla(api));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('El QR venció sin pagarse'), findsOneWidget);

    await tester.tap(find.text('Generar otro QR'));
    await tester.pump();
    await tester.pump();
    expect(posts, 2);
    expect(find.byKey(const Key('imagen-qr')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  group('botón de la oferta', () {
    Widget boton(PagosApi api) => MaterialApp(
      home: Scaffold(
        body: PagoQrBoton(ofertaId: 7, api: api),
      ),
    );

    testWidgets('muestra «Pagar con QR» si todavía no se pagó', (tester) async {
      await tester.pumpWidget(
        boton(_api(MockClient((r) async => _json({'estado': 'sin_cobro'})))),
      );
      await tester.pump();
      expect(find.text('Pagar con QR'), findsOneWidget);
    });

    testWidgets('muestra «Pagado» si la oferta ya se pagó', (tester) async {
      await tester.pumpWidget(
        boton(_api(MockClient((r) async => _json(_cobro('pagado'))))),
      );
      await tester.pump();
      expect(find.text('Pagado con QR · Bs 1.00'), findsOneWidget);
      expect(find.text('Pagar con QR'), findsNothing);
    });

    testWidgets('no aparece si la app se compiló sin PAGOS_URL', (
      tester,
    ) async {
      final api = PagosApi(
        base: '',
        cliente: MockClient((r) async => _json({})),
        token: () async => 't',
      );
      await tester.pumpWidget(boton(api));
      expect(find.text('Pagar con QR'), findsNothing);
    });
  });
}
