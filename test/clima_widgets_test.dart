import 'dart:convert';

import 'package:arreglaya/clima_service.dart';
import 'package:arreglaya/clima_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'al perder conexión, actualizar borra el dato anterior y muestra el error',
    (tester) async {
      var offline = false;
      final client = MockClient((request) async {
        if (offline) {
          throw http.ClientException('Sin conexión', request.url);
        }
        if (request.url.host == 'geocoding-api.open-meteo.com') {
          return http.Response(
            '{"results":[{"name":"Santa Cruz","admin1":"Santa Cruz",'
            '"country":"Bolivia","latitude":-17.78,"longitude":-63.18}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'current': {
              'temperature_2m': 24.4,
              'apparent_temperature': 25.1,
              'relative_humidity_2m': 58,
              'weather_code': 61,
              'wind_speed_10m': 7.2,
              'is_day': 1,
              'time': '2026-11-18T12:15',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = ClimaService(client: client);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TechnicianWeatherCard(zone: 'Santa Cruz', service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('24 °C'), findsOneWidget);

      offline = true;
      await tester.tap(find.byTooltip('Actualizar clima'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'No se pudo conectar al servicio del clima. Revisa tu conexión.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('24 °C'), findsNothing);
    },
  );
}
