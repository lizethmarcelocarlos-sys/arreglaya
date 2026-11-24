import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class TechnicianJobs extends StatelessWidget {
  const TechnicianJobs({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = Supabase.instance.client.auth.currentUser!.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Mis trabajos')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: Supabase.instance.client
            .from('offers')
            .stream(primaryKey: ['id'])
            .eq('technician_id', userId)
            .order('created_at', ascending: false),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  snapshot.error.toString(),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final offers = snapshot.data!;
          if (offers.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'Aún no enviaste ofertas. Busca trabajos disponibles en la pantalla principal.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Ofertas y servicios',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ...offers.map((offer) => TechnicianJobCard(offer: offer)),
            ],
          );
        },
      ),
    );
  }
}

class TechnicianJobCard extends StatelessWidget {
  const TechnicianJobCard({super.key, required this.offer});
  final Map<String, dynamic> offer;

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: Supabase.instance.client
        .from('service_requests')
        .select()
        .eq('id', offer['request_id'])
        .single(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('No se pudo cargar el servicio: ${snapshot.error}'),
          ),
        );
      }
      if (!snapshot.hasData)
        return const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        );
      final request = snapshot.data!;
      final accepted = offer['status'] == 'aceptada';
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      request['category'] as String,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  Chip(
                    label: Text(accepted ? 'Aceptada' : 'Esperando respuesta'),
                    backgroundColor: accepted
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    side: BorderSide.none,
                  ),
                ],
              ),
              Text(
                request['description'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text('Zona: ${request['zone']}'),
              Text('Tu oferta: Bs ${offer['price']}'),
              if (accepted)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'El cliente aceptó tu oferta. Coordina el servicio por WhatsApp.',
                    style: TextStyle(
                      color: Color(0xFF075E54),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (accepted)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            TechnicianServiceDetail(request: request),
                      ),
                    ),
                    icon: const Icon(Icons.location_on_outlined),
                    label: const Text('Ver detalles y ubicación'),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class TechnicianServiceDetail extends StatefulWidget {
  const TechnicianServiceDetail({super.key, required this.request});
  final Map<String, dynamic> request;

  @override
  State<TechnicianServiceDetail> createState() =>
      _TechnicianServiceDetailState();
}

class _TechnicianServiceDetailState extends State<TechnicianServiceDetail> {
  late Map<String, dynamic> request = widget.request;
  bool _updatingStage = false;

  Future<void> _updateStage(String stage) async {
    setState(() => _updatingStage = true);
    final values = <String, dynamic>{'work_stage': stage};
    if (stage == 'en_proceso')
      values['work_started_at'] = DateTime.now().toUtc().toIso8601String();
    if (stage == 'completado') {
      values['status'] = 'completada';
      values['completed_at'] = DateTime.now().toUtc().toIso8601String();
    }
    try {
      await Supabase.instance.client
          .from('service_requests')
          .update(values)
          .eq('id', request['id']);
      if (mounted) setState(() => request = {...request, ...values});
    } on PostgrestException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _updatingStage = false);
    }
  }

  Future<void> _openMap(BuildContext context) async {
    final latitude = this.request['latitude'];
    final longitude = this.request['longitude'];
    if (latitude == null || longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El cliente no registró una ubicación en el mapa.'),
        ),
      );
      return;
    }
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude',
    );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el mapa.')),
      );
    }
  }

  Future<void> _openWhatsApp(BuildContext context, String phone) async {
    final number = phone.replaceAll(RegExp(r'\D'), '');
    if (number.isEmpty) return;
    final text = Uri.encodeComponent(
      'Hola, soy el técnico que aceptó tu solicitud en ArreglaYa. ¿Podemos coordinar el servicio?',
    );
    final opened = await launchUrl(
      Uri.parse('https://wa.me/$number?text=$text'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final stage = request['work_stage'] as String? ?? 'aceptada';
    return Scaffold(
      appBar: AppBar(title: const Text('Servicio aceptado')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            request['category'] as String,
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            request['description'] as String,
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: const Text('Zona'),
            subtitle: Text(request['zone'] as String),
          ),
          FilledButton.icon(
            onPressed: () => _openMap(context),
            icon: const Icon(Icons.map_outlined),
            label: const Text('Abrir ubicación del cliente'),
          ),
          const SizedBox(height: 12),
          if (stage == 'aceptada')
            FilledButton.icon(
              onPressed: _updatingStage
                  ? null
                  : () => _updateStage('en_proceso'),
              icon: const Icon(Icons.play_circle_outline),
              label: Text(
                _updatingStage
                    ? 'Actualizando...'
                    : 'Marcar trabajo en proceso',
              ),
            )
          else if (stage == 'en_proceso')
            FilledButton.icon(
              onPressed: _updatingStage
                  ? null
                  : () => _updateStage('completado'),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(
                _updatingStage
                    ? 'Actualizando...'
                    : 'Marcar trabajo completado',
              ),
            )
          else
            const ListTile(
              leading: Icon(Icons.check_circle, color: Colors.green),
              title: Text('Trabajo completado'),
              subtitle: Text('El cliente ya puede calificar el servicio.'),
            ),
          const SizedBox(height: 24),
          Text(
            'Cliente',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          FutureBuilder<Map<String, dynamic>>(
            future: Supabase.instance.client
                .from('profiles')
                .select('full_name, phone')
                .eq('id', request['client_id'])
                .single(),
            builder: (context, snapshot) {
              if (!snapshot.hasData)
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                );
              final client = snapshot.data!;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(client['full_name'] as String),
                subtitle: Text(
                  client['phone'] as String? ?? 'Sin WhatsApp registrado',
                ),
                trailing: client['phone'] == null
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.chat_outlined),
                        onPressed: () =>
                            _openWhatsApp(context, client['phone'] as String),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }
}
