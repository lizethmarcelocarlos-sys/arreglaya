import 'package:flutter/material.dart';

import 'clima.dart';
import 'clima_service.dart';

class TechnicianWeatherCard extends StatefulWidget {
  const TechnicianWeatherCard({super.key, required this.zone, this.service});

  final String zone;
  final ClimaService? service;

  @override
  State<TechnicianWeatherCard> createState() => _TechnicianWeatherCardState();
}

class _TechnicianWeatherCardState extends State<TechnicianWeatherCard> {
  Clima? _climate;
  String? _error;
  bool _loading = true;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetch(++_requestId);
  }

  @override
  void didUpdateWidget(covariant TechnicianWeatherCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zone != widget.zone || oldWidget.service != widget.service) {
      _refresh();
    }
  }

  void _refresh() {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _climate = null;
      _error = null;
    });
    _fetch(requestId);
  }

  Future<void> _fetch(int requestId) async {
    try {
      final climate = await (widget.service ?? ClimaService()).obtenerPorZona(
        widget.zone,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _climate = climate;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = error is ClimaServiceException
            ? error.message
            : 'No se pudo cargar el clima en este momento.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const Row(
                children: [
                  SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Consultando el clima de la zona…'),
                ],
              )
            : _error != null
            ? Row(
                children: [
                  const Icon(Icons.cloud_off_outlined),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_error!)),
                  IconButton(
                    tooltip: 'Volver a consultar',
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              )
            : _climate == null
            ? const _WeatherMessage(
                icon: Icons.location_off_outlined,
                text: 'El técnico todavía no indicó su zona de trabajo.',
              )
            : _buildClimate(theme, _climate!),
      ),
    );
  }

  Widget _buildClimate(ThemeData theme, Clima climate) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(
            climate.isDay
                ? Icons.wb_sunny_outlined
                : Icons.nights_stay_outlined,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Clima en ${climate.location}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Actualizar clima',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '${climate.temperatureCelsius.round()} °C · ${climate.description}',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'Sensación ${climate.apparentTemperatureCelsius.round()} °C · '
        'Humedad ${climate.relativeHumidity}% · '
        'Viento ${climate.windSpeedKmh.round()} km/h',
      ),
      const SizedBox(height: 8),
      Text(
        'Dato actual de Open-Meteo · ${_formatTime(climate.time)}',
        style: theme.textTheme.bodySmall,
      ),
    ],
  );

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _WeatherMessage extends StatelessWidget {
  const _WeatherMessage({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon),
      const SizedBox(width: 12),
      Expanded(child: Text(text)),
    ],
  );
}
