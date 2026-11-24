import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class TechnicianContactActions extends StatelessWidget {
  const TechnicianContactActions({
    super.key,
    required this.phone,
    required this.workZone,
    required this.name,
  });

  final String? phone;
  final String workZone;
  final String name;

  String get _digits {
    final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length == 8) return '591$digits';
    return digits;
  }

  Future<void> _open(BuildContext context, Uri uri, String action) async {
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          context.mounted) {
        _showError(context, action);
      }
    } on Exception {
      if (context.mounted) _showError(context, action);
    }
  }

  void _showError(BuildContext context, String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No se pudo abrir $action en este dispositivo.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final zone = workZone.trim();
    final address = zone.toLowerCase().contains('bolivia')
        ? zone
        : '$zone, Bolivia';
    final hasPhone = _digits.length >= 8;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: hasPhone
              ? () => _open(
                  context,
                  Uri(scheme: 'tel', path: '+$_digits'),
                  'el marcador',
                )
              : null,
          icon: const Icon(Icons.call_outlined),
          label: const Text('Llamar'),
        ),
        FilledButton.tonalIcon(
          onPressed: hasPhone
              ? () {
                  final text = Uri.encodeComponent(
                    'Hola $name, te contacto desde ArreglaYa.',
                  );
                  _open(
                    context,
                    Uri.parse('https://wa.me/$_digits?text=$text'),
                    'WhatsApp',
                  );
                }
              : null,
          icon: const Icon(Icons.chat_outlined),
          label: const Text('WhatsApp'),
        ),
        OutlinedButton.icon(
          onPressed: zone.length >= 2
              ? () => _open(
                  context,
                  Uri.https('www.google.com', '/maps/dir/', {
                    'api': '1',
                    'destination': address,
                  }),
                  'Google Maps',
                )
              : null,
          icon: const Icon(Icons.directions_outlined),
          label: const Text('Cómo llegar'),
        ),
      ],
    );
  }
}
