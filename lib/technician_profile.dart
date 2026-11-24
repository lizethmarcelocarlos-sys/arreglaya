import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'clima_widgets.dart';
import 'technician_contact_actions.dart';

class TechnicianProfile extends StatefulWidget {
  const TechnicianProfile({
    super.key,
    required this.technicianId,
    required this.editable,
  });
  final String technicianId;
  final bool editable;

  @override
  State<TechnicianProfile> createState() => _TechnicianProfileState();
}

class _TechnicianProfileState extends State<TechnicianProfile> {
  Future<void> _editProfile(Map<String, dynamic> profile) async {
    final phone = TextEditingController(
      text: profile['phone'] as String? ?? '',
    );
    final specialties = TextEditingController(
      text: profile['specialties'] as String? ?? '',
    );
    final zone = TextEditingController(
      text: profile['work_zone'] as String? ?? '',
    );
    final years = TextEditingController(
      text: '${profile['experience_years'] ?? 0}',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar perfil'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'WhatsApp'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: specialties,
                decoration: const InputDecoration(labelText: 'Especialidades'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: zone,
                decoration: const InputDecoration(labelText: 'Zona de trabajo'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: years,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Años de experiencia',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await Supabase.instance.client
          .from('profiles')
          .update({
            'phone': phone.text.trim(),
            'specialties': specialties.text.trim(),
            'work_zone': zone.text.trim(),
            'experience_years': int.tryParse(years.text) ?? 0,
          })
          .eq('id', widget.technicianId);
      if (mounted) setState(() {});
    }
    phone.dispose();
    specialties.dispose();
    zone.dispose();
    years.dispose();
  }

  Future<void> _uploadAvatar() async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (image == null) return;
    final path = '${widget.technicianId}/avatar.jpg';
    await Supabase.instance.client.storage
        .from('profile-avatars')
        .uploadBinary(
          path,
          await image.readAsBytes(),
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    await Supabase.instance.client
        .from('profiles')
        .update({'avatar_path': path})
        .eq('id', widget.technicianId);
    if (mounted) setState(() {});
  }

  Future<void> _uploadDocument(String type) async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (image == null) return;
    final path = '${widget.technicianId}/$type.jpg';
    await Supabase.instance.client.storage
        .from('verification-documents')
        .uploadBinary(
          path,
          await image.readAsBytes(),
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    await Supabase.instance.client.from('verification_documents').upsert({
      'technician_id': widget.technicianId,
      'document_type': type,
      'path': path,
    }, onConflict: 'technician_id,document_type');
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Documento enviado para revisión.')),
      );
  }

  Future<void> _addPhotos() async {
    final images = await ImagePicker().pickMultiImage(imageQuality: 80);
    if (images.isEmpty) return;
    try {
      for (final image in images.take(3)) {
        final path =
            '${widget.technicianId}/${DateTime.now().microsecondsSinceEpoch}.jpg';
        await Supabase.instance.client.storage
            .from('technician-portfolio')
            .uploadBinary(
              path,
              await image.readAsBytes(),
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );
        await Supabase.instance.client.from('technician_portfolio').insert({
          'technician_id': widget.technicianId,
          'path': path,
        });
      }
      if (mounted) setState(() {});
    } on PostgrestException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.editable ? 'Mi perfil profesional' : 'Perfil del técnico',
      ),
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', widget.technicianId)
          .single(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final profile = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ProfileAvatar(path: profile['avatar_path'] as String?),
            if (widget.editable)
              Center(
                child: TextButton.icon(
                  onPressed: _uploadAvatar,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Cambiar foto de perfil'),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              profile['full_name'] as String,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (widget.editable)
              Center(
                child: TextButton.icon(
                  onPressed: () => _editProfile(profile),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Editar datos de perfil'),
                ),
              ),
            if (profile['verification_status'] == 'verificado')
              const Center(
                child: Chip(
                  avatar: Icon(Icons.verified, color: Colors.green),
                  label: Text('Técnico verificado'),
                ),
              ),
            const SizedBox(height: 14),
            _Info(
              label: 'Especialidades',
              value: profile['specialties'] as String? ?? 'No indicadas',
            ),
            _Info(
              label: 'Zona de trabajo',
              value: profile['work_zone'] as String? ?? 'No indicada',
            ),
            _Info(
              label: 'Experiencia',
              value: '${profile['experience_years'] ?? 0} años',
            ),
            const SizedBox(height: 16),
            TechnicianWeatherCard(zone: profile['work_zone'] as String? ?? ''),
            if (!widget.editable) ...[
              const SizedBox(height: 12),
              TechnicianContactActions(
                phone: profile['phone'] as String?,
                workZone: profile['work_zone'] as String? ?? '',
                name: profile['full_name'] as String? ?? 'técnico',
              ),
            ],
            TechnicianReviews(technicianId: widget.technicianId),
            const SizedBox(height: 20),
            Text(
              'Portafolio',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (widget.editable)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addPhotos,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Agregar fotos de trabajos'),
                ),
              ),
            PortfolioGallery(technicianId: widget.technicianId),
            if (widget.editable) ...[
              const SizedBox(height: 20),
              Text(
                'Documentos de verificación',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Text('Solo el administrador puede verlos.'),
              TextButton.icon(
                onPressed: () => _uploadDocument('carnet_anverso'),
                icon: const Icon(Icons.badge_outlined),
                label: const Text('Subir carnet anverso'),
              ),
              TextButton.icon(
                onPressed: () => _uploadDocument('carnet_reverso'),
                icon: const Icon(Icons.badge_outlined),
                label: const Text('Subir carnet reverso'),
              ),
            ],
          ],
        );
      },
    ),
  );
}

class _Info extends StatelessWidget {
  const _Info({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.check_circle_outline),
    title: Text(label),
    subtitle: Text(value),
  );
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.path});
  final String? path;
  @override
  Widget build(BuildContext context) {
    if (path == null)
      return const Center(
        child: CircleAvatar(
          radius: 42,
          child: Icon(Icons.engineering, size: 42),
        ),
      );
    return Center(
      child: FutureBuilder<String>(
        future: Supabase.instance.client.storage
            .from('profile-avatars')
            .createSignedUrl(path!, 3600),
        builder: (context, snapshot) => CircleAvatar(
          radius: 42,
          backgroundImage: snapshot.hasData
              ? NetworkImage(snapshot.data!)
              : null,
          child: snapshot.hasData ? null : const CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class TechnicianReviews extends StatelessWidget {
  const TechnicianReviews({super.key, required this.technicianId});
  final String technicianId;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, dynamic>>>(
        future: Supabase.instance.client
            .from('service_reviews')
            .select('rating, comment, created_at')
            .eq('technician_id', technicianId)
            .order('created_at', ascending: false),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            );
          final reviews = snapshot.data!;
          if (reviews.isEmpty)
            return const ListTile(
              leading: Icon(Icons.star_border),
              title: Text('Aún no tiene calificaciones'),
            );
          final average =
              reviews.fold<int>(
                0,
                (total, review) => total + (review['rating'] as int),
              ) /
              reviews.length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.star, color: Colors.amber),
                title: Text('${average.toStringAsFixed(1)} de 5 estrellas'),
                subtitle: Text(
                  '${reviews.length} calificación(es) de clientes',
                ),
              ),
              Text(
                'Reseñas',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              ...reviews
                  .take(3)
                  .map(
                    (review) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text('★' * (review['rating'] as int)),
                        subtitle: Text(
                          review['comment'] as String? ??
                              'Cliente verificado no dejó un comentario.',
                        ),
                      ),
                    ),
                  ),
            ],
          );
        },
      );
}

class PortfolioGallery extends StatelessWidget {
  const PortfolioGallery({super.key, required this.technicianId});
  final String technicianId;
  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, dynamic>>>(
        future: Supabase.instance.client
            .from('technician_portfolio')
            .select('path')
            .eq('technician_id', technicianId)
            .order('created_at', ascending: false),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            );
          final images = snapshot.data!;
          if (images.isEmpty)
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Este técnico aún no agregó fotos de trabajos.'),
            );
          return SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) =>
                  PortfolioImage(path: images[i]['path'] as String),
            ),
          );
        },
      );
}

class PortfolioImage extends StatelessWidget {
  const PortfolioImage({super.key, required this.path});
  final String path;
  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: Supabase.instance.client.storage
        .from('technician-portfolio')
        .createSignedUrl(path, 3600),
    builder: (context, snapshot) {
      if (!snapshot.hasData)
        return const SizedBox(
          width: 150,
          child: Center(child: CircularProgressIndicator()),
        );
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          snapshot.data!,
          width: 150,
          height: 150,
          fit: BoxFit.cover,
        ),
      );
    },
  );
}
