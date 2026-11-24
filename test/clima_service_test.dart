import 'dart:convert';
import 'dart:async';

import 'package:arreglaya/clima.dart';
import 'package:arreglaya/clima_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final current = <String, dynamic>{
    'temperature_2m': 24.4,
    'apparent_temperature': 25.1,
    'relative_humidity_2m': 58,
    'weather_code': 61,
    'wind_speed_10m': 7.2,
    'is_day': 1,
    'time': '2026-11-18T12:15',
  };

  test(
    'Clima.fromJson convierte las condiciones actuales en valores tipados',
    () {
      final climate = Clima.fromJson({
        'current': current,
      }, location: 'Santa Cruz, Bolivia');

      expect(climate.location, 'Santa Cruz, Bolivia');
      expect(climate.temperatureCelsius, 24.4);
      expect(climate.relativeHumidity, 58);
      expect(climate.description, 'Lluvia');
      expect(climate.isDay, isTrue);
    },
  );

  test(
    'ClimaService busca la zona y consulta Open-Meteo con sus coordenadas',
    () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'geocoding-api.open-meteo.com') {
          return http.Response(
            '{"results":[{"name":"Santa Cruz","admin1":"Santa Cruz","country":"Bolivia","latitude":-17.78,"longitude":-63.18}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'current': current}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final climate = await ClimaService(client: client)
          .obtenerPorZona('Santa Cruz');

      expect(requests, hasLength(2));
      expect(requests.first.queryParameters['countryCode'], 'BO');
      expect(requests.last.queryParameters['latitude'], '-17.78');
      expect(requests.last.queryParameters['longitude'], '-63.18');
      expect(
        requests.last.queryParameters['current'],
        contains('weather_code'),
      );
      expect(climate.location, 'Santa Cruz, Bolivia');
      expect(climate.temperatureCelsius, 24.4);
    },
  );

  test('ClimaService explica errores de conexión HTTP', () async {
    final client = MockClient((_) async => http.Response('sin servicio', 503));

    await expectLater(
      ClimaService(client: client).obtenerPorZona('Cochabamba'),
      throwsA(
        isA<ClimaServiceException>().having(
          (error) => error.message,
          'mensaje',
          contains('503'),
        ),
      ),
    );
  });

  test('ClimaService corta una petición que supera el tiempo límite', () async {
    final client = MockClient((_) => Completer<http.Response>().future);

    await expectLater(
      ClimaService(
        client: client,
        timeout: const Duration(milliseconds: 5),
      ).obtenerPorZona('Santa Cruz'),
      throwsA(
        isA<ClimaServiceException>().having(
          (error) => error.message,
          'mensaje',
          contains('tardó demasiado'),
        ),
      ),
    );
  });
}
