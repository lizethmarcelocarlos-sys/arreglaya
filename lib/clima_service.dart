import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'clima.dart';

class ClimaServiceException implements Exception {
  const ClimaServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ClimaService {
  ClimaService({this.client, this.timeout = const Duration(seconds: 10)});

  final http.Client? client;
  final Duration timeout;

  Future<Clima> obtenerPorZona(String zone) async {
    final normalizedZone = zone.trim();
    if (normalizedZone.length < 2) {
      throw const ClimaServiceException(
        'El técnico todavía no indicó su zona de trabajo.',
      );
    }

    final placeData = await _getJson(
      Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
        'name': normalizedZone,
        'count': '1',
        'language': 'es',
        'format': 'json',
        'countryCode': 'BO',
      }),
    );
    final results = placeData['results'];
    if (results is! List ||
        results.isEmpty ||
        results.first is! Map<String, dynamic>) {
      throw const ClimaServiceException('No encontramos el clima de esa zona.');
    }

    final place = results.first as Map<String, dynamic>;
    final latitude = place['latitude'];
    final longitude = place['longitude'];
    if (latitude is! num || longitude is! num) {
      throw const ClimaServiceException(
        'La zona no tiene coordenadas disponibles.',
      );
    }
    final placeName = [place['name'], place['admin1'], place['country']]
        .whereType<String>()
        .where((part) => part.trim().isNotEmpty)
        .toSet()
        .join(', ');

    final forecast = await _getJson(
      Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current': 'temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day',
        'timezone': 'auto',
      }),
    );

    try {
      return Clima.fromJson(forecast, location: placeName);
    } on FormatException catch (error) {
      throw ClimaServiceException(
        'La respuesta del clima no es válida: ${error.message}',
      );
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final activeClient = client ?? http.Client();
    try {
      final response = await activeClient
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw ClimaServiceException(
          'El servicio del clima respondió con el código ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const ClimaServiceException(
          'El servicio devolvió una respuesta inesperada.',
        );
      }
      return decoded;
    } on TimeoutException {
      throw const ClimaServiceException(
        'La consulta del clima tardó demasiado. Revisa tu conexión e inténtalo de nuevo.',
      );
    } on http.ClientException {
      throw const ClimaServiceException(
        'No se pudo conectar al servicio del clima. Revisa tu conexión.',
      );
    } on FormatException {
      throw const ClimaServiceException(
        'El servicio del clima devolvió un JSON no válido.',
      );
    } finally {
      if (client == null) activeClient.close();
    }
  }
}
