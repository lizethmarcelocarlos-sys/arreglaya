import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class TechnicianMap extends StatefulWidget {
  const TechnicianMap({super.key});

  @override
  State<TechnicianMap> createState() => _TechnicianMapState();
}

class _TechnicianMapState extends State<TechnicianMap> {
  static const _santaCruz = LatLng(-17.7833, -63.1821);
  final _controller = MapController();
  LatLng? _myLocation;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _findMyLocation();
  }

  Future<void> _findMyLocation() async {
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever)
        return;
      final position = await Geolocator.getCurrentPosition();
      final location = LatLng(position.latitude, position.longitude);
      if (mounted) {
        setState(() => _myLocation = location);
        _controller.move(location, 13);
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  double? _distanceTo(Map<String, dynamic> request) {
    if (_myLocation == null ||
        request['latitude'] == null ||
        request['longitude'] == null)
      return null;
    return const Distance().as(
      LengthUnit.Kilometer,
      _myLocation!,
      LatLng(
        (request['latitude'] as num).toDouble(),
        (request['longitude'] as num).toDouble(),
      ),
    );
  }

  // El mapa de descubrimiento muestra un área aproximada, no la dirección exacta.
  double _approximate(num coordinate) =>
      (coordinate.toDouble() * 100).roundToDouble() / 100;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Trabajos cercanos'),
      actions: [
        IconButton(
          tooltip: 'Mi ubicación',
          onPressed: _locating ? null : _findMyLocation,
          icon: const Icon(Icons.my_location),
        ),
      ],
    ),
    body: StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('service_requests')
          .stream(primaryKey: ['id'])
          .eq('status', 'pendiente')
          .order('created_at', ascending: false),
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                snapshot.error.toString(),
                textAlign: TextAlign.center,
              ),
            ),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final requests = snapshot.data!
            .where((r) => r['latitude'] != null && r['longitude'] != null)
            .toList();
        if (requests.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Text(
                'No hay trabajos con ubicación en el mapa todavía.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: _myLocation ?? _santaCruz,
            initialZoom: 12,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.arreglaya',
            ),
            if (_myLocation != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: _myLocation!,
                    width: 42,
                    height: 42,
                    child: const Icon(
                      Icons.person_pin_circle,
                      size: 42,
                      color: Color(0xFF075E54),
                    ),
                  ),
                ],
              ),
            MarkerLayer(
              markers: requests.map((request) {
                final location = LatLng(
                  _approximate(request['latitude'] as num),
                  _approximate(request['longitude'] as num),
                );
                return Marker(
                  point: location,
                  width: 50,
                  height: 50,
                  child: GestureDetector(
                    onTap: () => _showRequest(request),
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.red,
                      size: 46,
                    ),
                  ),
                );
              }).toList(),
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
        );
      },
    ),
  );

  void _showRequest(Map<String, dynamic> request) {
    final distance = _distanceTo(request);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              request['category'] as String,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(request['zone'] as String),
            if (distance != null)
              Text('A ${distance.toStringAsFixed(1)} km de ti'),
            const SizedBox(height: 8),
            Text(
              request['description'] as String,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
