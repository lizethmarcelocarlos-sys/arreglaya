import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class MapPicker extends StatefulWidget {
  const MapPicker({super.key, this.initialLocation});
  final LatLng? initialLocation;

  @override
  State<MapPicker> createState() => _MapPickerState();
}

class _MapPickerState extends State<MapPicker> {
  static const _santaCruz = LatLng(-17.7833, -63.1821);
  late LatLng _selected = widget.initialLocation ?? _santaCruz;
  final _controller = MapController();
  bool _findingLocation = false;

  Future<void> _useCurrentLocation() async {
    setState(() => _findingLocation = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Debes permitir la ubicación para usar esta opción.',
              ),
            ),
          );
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      final location = LatLng(position.latitude, position.longitude);
      if (mounted) {
        setState(() => _selected = location);
        _controller.move(location, 16);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo obtener tu ubicación. Coloca el pin manualmente.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _findingLocation = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ubicación del servicio')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Toca el mapa para ubicar el problema. La ubicación exacta solo se comparte cuando aceptes una oferta.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        Expanded(
          child: FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _selected,
              initialZoom: 13,
              onTap: (_, location) => setState(() => _selected = location),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.arreglaya',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _selected,
                    width: 50,
                    height: 50,
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.red,
                      size: 46,
                    ),
                  ),
                ],
              ),
              RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () => launchUrl(
                      Uri.https('www.openstreetmap.org', '/copyright'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _findingLocation ? null : _useCurrentLocation,
                  icon: const Icon(Icons.my_location),
                  label: Text(
                    _findingLocation
                        ? 'Buscando ubicación...'
                        : 'Usar mi ubicación actual',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Confirmar ubicación'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
