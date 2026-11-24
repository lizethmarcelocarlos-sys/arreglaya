class Clima {
  const Clima({
    required this.location,
    required this.temperatureCelsius,
    required this.apparentTemperatureCelsius,
    required this.relativeHumidity,
    required this.windSpeedKmh,
    required this.weatherCode,
    required this.isDay,
    required this.time,
  });

  final String location;
  final double temperatureCelsius;
  final double apparentTemperatureCelsius;
  final int relativeHumidity;
  final double windSpeedKmh;
  final int weatherCode;
  final bool isDay;
  final DateTime time;

  factory Clima.fromJson(Map<String, dynamic> json, {String? location}) {
    final current = json['current'];
    if (current is! Map<String, dynamic>) {
      throw const FormatException(
        'La respuesta no contiene las condiciones actuales.',
      );
    }

    double number(String key) {
      final value = current[key];
      if (value is num) return value.toDouble();
      throw FormatException('El dato "$key" no es un número válido.');
    }

    final humidity = number('relative_humidity_2m');
    final day = number('is_day');
    final code = number('weather_code');
    final time = current['time'];
    if (time is! String) {
      throw const FormatException(
        'La respuesta no contiene la hora de medición.',
      );
    }

    return Clima(
      location: location ?? 'Zona del técnico',
      temperatureCelsius: number('temperature_2m'),
      apparentTemperatureCelsius: number('apparent_temperature'),
      relativeHumidity: humidity.round(),
      windSpeedKmh: number('wind_speed_10m'),
      weatherCode: code.round(),
      isDay: day == 1,
      time: DateTime.parse(time),
    );
  }

  String get description => switch (weatherCode) {
    0 => 'Cielo despejado',
    1 => 'Mayormente despejado',
    2 => 'Parcialmente nublado',
    3 => 'Nublado',
    45 || 48 => 'Niebla',
    51 || 53 || 55 || 56 || 57 => 'Llovizna',
    61 || 63 || 65 || 66 || 67 => 'Lluvia',
    71 || 73 || 75 || 77 => 'Nevada',
    80 || 81 || 82 => 'Chubascos',
    85 || 86 => 'Chubascos de nieve',
    95 || 96 || 97 || 99 => 'Tormenta',
    _ => 'Condición variable',
  };
}
