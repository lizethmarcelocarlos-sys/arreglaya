import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'map_picker.dart';
import 'pago_qr.dart';
import 'technician_jobs.dart';
import 'technician_map.dart';
import 'technician_profile.dart';

const _supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://prdzxcybmcxprzjsovuy.supabase.co',
);
const _supabaseKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_1hBCuPZMicJRBQiSON3_2A_-x2_uOZu',
);
const _authRedirectUrl = 'io.arreglaya.app://login-callback';

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  await FirebaseMessaging.instance.requestPermission();
  final configured = _supabaseUrl.isNotEmpty && _supabaseKey.isNotEmpty;
  if (configured) {
    await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseKey);
  }
  runApp(ArreglaYaApp(configured: configured));
}

class ArreglaYaApp extends StatelessWidget {
  const ArreglaYaApp({super.key, required this.configured});
  final bool configured;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'ArreglaYa',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF075E54),
        primary: const Color(0xFF075E54),
        secondary: const Color(0xFFFFB800),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFFCCD8D6)),
        ),
      ),
    ),
    home: configured ? const AuthGate() : const SetupScreen(),
  );
}

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.handyman_rounded,
              size: 64,
              color: Color(0xFF075E54),
            ),
            const SizedBox(height: 20),
            Text(
              'ArreglaYa está listo',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'Falta conectar tu proyecto de Supabase. Ejecuta primero el archivo supabase/schema.sql en el SQL Editor de Supabase.',
            ),
            const SizedBox(height: 24),
            const SelectableText(
              'flutter run --dart-define=SUPABASE_URL=https://TU-PROYECTO.supabase.co --dart-define=SUPABASE_ANON_KEY=TU_CLAVE_PUBLICA',
            ),
          ],
        ),
      ),
    ),
  );
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: Supabase.instance.client.auth.onAuthStateChange,
    builder: (context, snapshot) {
      final session = Supabase.instance.client.auth.currentSession;
      return session == null ? const AuthScreen() : const Dashboard();
    },
  );
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.signIn});

  final Future<void> Function(String email, String password)? signIn;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _specialties = TextEditingController();
  final _workZone = TextEditingController();
  final _experienceYears = TextEditingController();
  bool _login = true;
  bool _loading = false;
  bool _hidePassword = true;
  String _role = 'cliente';
  int _failedAttempts = 0;
  DateTime? _lockedUntil;
  Timer? _cooldownTimer;

  int get _secondsRemaining {
    final milliseconds =
        _lockedUntil?.difference(DateTime.now()).inMilliseconds ?? 0;
    return milliseconds > 0 ? (milliseconds / 1000).ceil() : 0;
  }

  void _startCooldown() {
    _lockedUntil = DateTime.now().add(const Duration(seconds: 30));
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_secondsRemaining == 0 || timer.tick >= 30) {
          _failedAttempts = 0;
          _lockedUntil = null;
          timer.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _phone.dispose();
    _specialties.dispose();
    _workZone.dispose();
    _experienceYears.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading || (_login && _secondsRemaining > 0)) return;
    if (_login && _lockedUntil != null) {
      _failedAttempts = 0;
      _lockedUntil = null;
    }
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      if (_login) {
        if (widget.signIn != null) {
          await widget.signIn!(_email.text.trim(), _password.text);
        } else {
          await Supabase.instance.client.auth.signInWithPassword(
            email: _email.text.trim(),
            password: _password.text,
          );
        }
        _failedAttempts = 0;
      } else {
        final auth = Supabase.instance.client.auth;
        await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          emailRedirectTo:
              !kIsWeb &&
                  (defaultTargetPlatform == TargetPlatform.android ||
                      defaultTargetPlatform == TargetPlatform.iOS)
              ? _authRedirectUrl
              : null,
          data: {
            'app': 'arreglaya',
            'full_name': _name.text.trim(),
            'role': _role,
            'phone': _phone.text.trim(),
            'specialties': _specialties.text.trim(),
            'work_zone': _workZone.text.trim(),
            'experience_years': _experienceYears.text.trim(),
          },
        );
        if (mounted && auth.currentSession == null) {
          _notice(
            'Revisa tu correo y abre el enlace de confirmación en este teléfono para volver a ArreglaYa.',
          );
        }
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      if (_login && e.code == 'invalid_credentials') {
        _failedAttempts++;
        if (_failedAttempts >= 3) {
          _startCooldown();
          _notice(
            'Tres intentos fallidos. Espera 30 segundos para volver a ingresar.',
            error: true,
          );
        } else {
          _notice(
            'Correo o contraseña incorrectos. Intentos restantes: ${3 - _failedAttempts}.',
            error: true,
          );
        }
      } else if (e.code == 'over_email_send_rate_limit') {
        _notice(
          'Se alcanzó el límite de correos de confirmación de Supabase. Intenta más tarde; este límite es distinto de la espera de 30 segundos.',
          error: true,
        );
      } else {
        _notice(e.message, error: true);
      }
    } catch (_) {
      _notice('No se pudo conectar. Intenta nuevamente.', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _notice(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Colors.red.shade700 : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.handyman_rounded,
                    color: Color(0xFF075E54),
                    size: 68,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'ArreglaYa',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _login
                        ? 'Entra para encontrar o brindar ayuda.'
                        : 'Crea tu cuenta y conecta soluciones.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  if (!_login) ...[
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Nombre completo',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (v) => (v == null || v.trim().length < 2)
                          ? 'Ingresa tu nombre'
                          : null,
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Correo electrónico',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Ingresa un correo válido'
                        : null,
                  ),
                  if (!_login) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'WhatsApp',
                        hintText: 'Ej. 59170000000',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      validator: (v) {
                        final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                        return digits.length < 8
                            ? 'Ingresa tu número con código de país'
                            : null;
                      },
                    ),
                    if (_role == 'tecnico') ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _specialties,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Especialidades',
                          hintText: 'Ej. Albañilería, pintura, soldadura',
                          prefixIcon: Icon(Icons.handyman_outlined),
                        ),
                        validator: (v) =>
                            _role == 'tecnico' &&
                                (v == null || v.trim().length < 3)
                            ? 'Indica al menos una especialidad'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _workZone,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Zona donde trabajas',
                          prefixIcon: Icon(Icons.location_on_outlined),
                        ),
                        validator: (v) =>
                            _role == 'tecnico' &&
                                (v == null || v.trim().length < 2)
                            ? 'Indica tu zona de trabajo'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _experienceYears,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Años de experiencia',
                          prefixIcon: Icon(Icons.workspace_premium_outlined),
                        ),
                        validator: (v) =>
                            _role == 'tecnico' && int.tryParse(v ?? '') == null
                            ? 'Ingresa los años de experiencia'
                            : null,
                      ),
                    ],
                  ],
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: _hidePassword,
                    decoration: InputDecoration(
                      labelText: 'Contraseña',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _hidePassword
                            ? 'Mostrar contraseña'
                            : 'Ocultar contraseña',
                        onPressed: () =>
                            setState(() => _hidePassword = !_hidePassword),
                        icon: Icon(
                          _hidePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'Mínimo 6 caracteres'
                        : null,
                  ),
                  if (!_login) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Quiero usar ArreglaYa como',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'cliente',
                      groupValue: _role,
                      onChanged: (v) => setState(() => _role = v!),
                      title: const Text('Cliente'),
                      subtitle: const Text('Necesito reparar algo'),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'tecnico',
                      groupValue: _role,
                      onChanged: (v) => setState(() => _role = v!),
                      title: const Text('Técnico'),
                      subtitle: const Text('Ofrezco mis servicios'),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _loading || (_login && _secondsRemaining > 0)
                        ? null
                        : _submit,
                    child: Padding(
                      padding: const EdgeInsets.all(13),
                      child: _loading
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _login
                                  ? (_secondsRemaining > 0
                                        ? 'Espera $_secondsRemaining s'
                                        : 'Ingresar')
                                  : 'Crear cuenta',
                            ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => setState(() => _login = !_login),
                    child: Text(
                      _login
                          ? '¿No tienes cuenta? Regístrate'
                          : '¿Ya tienes cuenta? Ingresa',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class Dashboard extends StatelessWidget {
  const Dashboard({super.key});
  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser!;
    return FutureBuilder<Map<String, dynamic>>(
      future: Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .single(),
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Scaffold(
            body: Center(
              child: Text(
                'No se pudo cargar tu perfil.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        if (!snapshot.hasData)
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        final profile = snapshot.data!;
        final role = profile['role'] as String;
        if (role == 'admin') return const AdminHome();
        if (role == 'tecnico' &&
            profile['verification_status'] != 'verificado') {
          return PendingVerificationHome(
            name: profile['full_name'] as String,
            status: profile['verification_status'] as String,
          );
        }
        return role == 'tecnico'
            ? TechnicianHome(name: profile['full_name'] as String)
            : ClientHome(name: profile['full_name'] as String, userId: user.id);
      },
    );
  }
}

class ClientHome extends StatelessWidget {
  ClientHome({super.key, required this.name, required this.userId});
  final String name, userId;

  final SpeechToText _voiceSpeech = SpeechToText();
  final TextEditingController _voiceSearchController = TextEditingController();
  final ValueNotifier<bool> _voiceListeningNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String> _voiceQueryNotifier = ValueNotifier<String>('');

  Future<void> _toggleVoiceSearch() async {
    if (_voiceListeningNotifier.value) {
      await _voiceSpeech.stop();
      _voiceListeningNotifier.value = false;
      return;
    }
    final available = await _voiceSpeech.initialize();
    if (!available) return;
    _voiceListeningNotifier.value = true;
    await _voiceSpeech.listen(
      localeId: 'es_BO',
      onResult: (result) {
        _voiceSearchController.text = result.recognizedWords;
        _voiceSearchController.selection = TextSelection.fromPosition(
          TextPosition(offset: _voiceSearchController.text.length),
        );
        _voiceQueryNotifier.value = result.recognizedWords.trim().toLowerCase();
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _appBar(context, 'Hola, ${name.split(' ').first}'),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RequestForm()),
      ),
      icon: const Icon(Icons.add),
      label: const Text('Solicitar ayuda'),
    ),
    body: StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('service_requests')
          .stream(primaryKey: ['id'])
          .eq('client_id', userId)
          .order('created_at', ascending: false),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadError(message: snapshot.error.toString());
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final requests = snapshot.data!;
        if (requests.isEmpty) {
          return const EmptyState(
            icon: Icons.build_outlined,
            title: '¿Qué necesitas arreglar hoy?',
            subtitle:
                'Publica una solicitud y técnicos de tu zona podrán enviarte ofertas.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            Text(
              'Mis solicitudes',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<bool>(
              valueListenable: _voiceListeningNotifier,
              builder: (context, isListening, _) {
                return TextField(
                  controller: _voiceSearchController,
                  decoration: InputDecoration(
                    hintText: 'Buscar solicitud o hablar...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      icon: Icon(isListening ? Icons.mic : Icons.mic_none),
                      onPressed: _toggleVoiceSearch,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (value) {
                    _voiceQueryNotifier.value = value.trim().toLowerCase();
                  },
                );
              },
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<String>(
              valueListenable: _voiceQueryNotifier,
              builder: (context, query, _) {
                final filtered = requests.where((r) {
                  if (query.isEmpty) return true;
                  return r.toString().toLowerCase().contains(query);
                }).toList();
                return Column(
                  children: filtered
                      .map(
                        (r) => RequestCard(
                          request: r,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  RequestDetail(request: r, clientView: true),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
          ],
        );
      },
    ),
  );
}
class TechnicianHome extends StatelessWidget {
  const TechnicianHome({super.key, required this.name});
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        'Hola, ${name.split(' ').first}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      actions: [
        IconButton(
          tooltip: 'Mi perfil',
          icon: const Icon(Icons.person_outline),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TechnicianProfile(
                technicianId: Supabase.instance.client.auth.currentUser!.id,
                editable: true,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Mis trabajos',
          icon: const Icon(Icons.work_outline),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TechnicianJobs()),
          ),
        ),
        IconButton(
          tooltip: 'Mapa de trabajos',
          icon: const Icon(Icons.map_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TechnicianMap()),
          ),
        ),
        IconButton(
          tooltip: 'Cerrar sesión',
          icon: const Icon(Icons.logout),
          onPressed: () => Supabase.instance.client.auth.signOut(),
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
        if (snapshot.hasError) {
          return LoadError(message: snapshot.error.toString());
        }
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final requests = snapshot.data!;
        if (requests.isEmpty)
          return const EmptyState(
            icon: Icons.search_off_outlined,
            title: 'No hay solicitudes nuevas',
            subtitle: 'Vuelve pronto para conocer nuevos trabajos cerca de ti.',
          );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Trabajos disponibles',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ...requests.map(
              (r) => RequestCard(
                request: r,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        RequestDetail(request: r, clientView: false),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class PendingVerificationHome extends StatelessWidget {
  const PendingVerificationHome({
    super.key,
    required this.name,
    required this.status,
  });
  final String name;
  final String status;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _appBar(context, 'Hola, ${name.split(' ').first}'),
    body: EmptyState(
      icon: status == 'rechazado'
          ? Icons.cancel_outlined
          : Icons.verified_user_outlined,
      title: status == 'rechazado'
          ? 'Tu verificación fue rechazada'
          : 'Tu perfil está en revisión',
      subtitle: status == 'rechazado'
          ? 'Comunícate con ArreglaYa para actualizar tus datos.'
          : 'Un administrador revisará tus especialidades y datos. Podrás enviar ofertas cuando seas verificado.',
    ),
  );
}

class AdminHome extends StatelessWidget {
  const AdminHome({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _appBar(context, 'Panel administrador'),
    body: StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('profiles')
          .stream(primaryKey: ['id'])
          .eq('role', 'tecnico')
          .eq('verification_status', 'pendiente')
          .order('created_at'),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadError(message: snapshot.error.toString());
        }
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final technicians = snapshot.data!;
        if (technicians.isEmpty) {
          return const EmptyState(
            icon: Icons.verified_outlined,
            title: 'No hay técnicos pendientes',
            subtitle: 'Las nuevas solicitudes de verificación aparecerán aquí.',
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Verificaciones pendientes',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ...technicians.map(
              (technician) =>
                  TechnicianVerificationCard(technician: technician),
            ),
          ],
        );
      },
    ),
  );
}

class TechnicianVerificationCard extends StatelessWidget {
  const TechnicianVerificationCard({super.key, required this.technician});
  final Map<String, dynamic> technician;

  Future<void> _setStatus(BuildContext context, String status) async {
    try {
      await Supabase.instance.client.rpc(
        'verify_technician',
        params: {'p_technician_id': technician['id'], 'p_status': status},
      );
    } on PostgrestException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            technician['full_name'] as String,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
          ),
          const SizedBox(height: 8),
          Text(
            'Especialidades: ${technician['specialties'] ?? 'No indicadas'}',
          ),
          Text('Zona: ${technician['work_zone'] ?? 'No indicada'}'),
          Text('Experiencia: ${technician['experience_years'] ?? 0} años'),
          Text('WhatsApp: ${technician['phone'] ?? 'No indicado'}'),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _setStatus(context, 'rechazado'),
                child: const Text('Rechazar'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _setStatus(context, 'verificado'),
                icon: const Icon(Icons.verified),
                label: const Text('Aprobar'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class LoadError extends StatelessWidget {
  const LoadError({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 52, color: Colors.red),
          const SizedBox(height: 12),
          Text(
            'No se pudieron cargar los datos',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

PreferredSizeWidget _appBar(BuildContext context, String title) => AppBar(
  title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
  actions: [
    IconButton(
      tooltip: 'Cerrar sesión',
      icon: const Icon(Icons.logout),
      onPressed: () => Supabase.instance.client.auth.signOut(),
    ),
  ],
);

class RequestCard extends StatelessWidget {
  const RequestCard({super.key, required this.request, required this.onTap});
  final Map<String, dynamic> request;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final createdAt = DateTime.tryParse(request['created_at'] as String? ?? '');
    final requestedAt = DateTime.tryParse(
      request['requested_at'] as String? ?? '',
    );
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: const Color(0xFFE0F2F0),
                    child: Icon(
                      _categoryIcon(request['category'] as String),
                      color: const Color(0xFF075E54),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      request['category'] as String,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  StatusChip(status: request['status'] as String),
                ],
              ),
              const SizedBox(height: 12),
              if (request['urgency'] != null && request['urgency'] != 'normal')
                Align(
                  alignment: Alignment.centerLeft,
                  child: Chip(
                    avatar: Icon(
                      request['urgency'] == 'emergencia'
                          ? Icons.warning_amber_rounded
                          : Icons.today_outlined,
                      color: request['urgency'] == 'emergencia'
                          ? Colors.red.shade700
                          : Colors.orange.shade700,
                      size: 18,
                    ),
                    label: Text(
                      request['urgency'] == 'emergencia'
                          ? 'Emergencia'
                          : 'Lo necesita hoy',
                    ),
                    backgroundColor: request['urgency'] == 'emergencia'
                        ? Colors.red.shade50
                        : Colors.orange.shade50,
                    side: BorderSide.none,
                  ),
                ),
              Text(
                request['description'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.location_on_outlined, size: 18),
                  const SizedBox(width: 4),
                  Text(request['zone'] as String),
                ],
              ),
              const SizedBox(height: 8),
              if (createdAt != null)
                Text(
                  'Publicado: ${_formatDateTime(context, createdAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (requestedAt != null)
                Text(
                  'Lo necesita: ${_formatDateTime(context, requestedAt)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF075E54),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (request['work_stage'] == 'en_proceso')
                Text(
                  'El técnico está trabajando en tu solicitud',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF075E54),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDateTime(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final localizations = MaterialLocalizations.of(context);
  return '${localizations.formatShortDate(local)} · ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'pendiente' => Colors.orange,
      'aceptada' => Colors.blue,
      'completada' => Colors.green,
      _ => Colors.grey,
    };
    return Chip(
      label: Text(status[0].toUpperCase() + status.substring(1)),
      labelStyle: TextStyle(color: color.shade800, fontSize: 12),
      backgroundColor: color.shade50,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );
  }
}

IconData _categoryIcon(String c) => switch (c) {
  'Electricidad' => Icons.bolt_rounded,
  'Plomería' => Icons.water_drop_outlined,
  'Computadoras' => Icons.computer_outlined,
  'Celulares' => Icons.phone_android_outlined,
  'Electrodomésticos' => Icons.kitchen_outlined,
  _ => Icons.build_outlined,
};

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: const Color(0xFF075E54)),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(subtitle, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class RequestForm extends StatefulWidget {
  const RequestForm({super.key});
  @override
  State<RequestForm> createState() => _RequestFormState();
}

class _RequestFormState extends State<RequestForm> {
  final _form = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _zone = TextEditingController();
  String _category = 'Electricidad';
  bool _saving = false;
  DateTime? _requestedAt;
  double? _latitude;
  double? _longitude;
  String _urgency = 'normal';
  final _imagePicker = ImagePicker();
  final List<XFile> _photos = [];
  @override
  void dispose() {
    _description.dispose();
    _zone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final userId = Supabase.instance.client.auth.currentUser!.id;
      final created = await Supabase.instance.client
          .from('service_requests')
          .insert({
            'client_id': Supabase.instance.client.auth.currentUser!.id,
            'category': _category,
            'description': _description.text.trim(),
            'zone': _zone.text.trim(),
            'requested_at': _requestedAt?.toUtc().toIso8601String(),
            'latitude': _latitude,
            'longitude': _longitude,
            'urgency': _urgency,
          })
          .select('id')
          .single();
      for (final photo in _photos) {
        final bytes = await photo.readAsBytes();
        final path =
            '$userId/${created['id']}/${DateTime.now().microsecondsSinceEpoch}.jpg';
        await Supabase.instance.client.storage
            .from('request-media')
            .uploadBinary(
              path,
              bytes,
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );
        await Supabase.instance.client.from('request_images').insert({
          'request_id': created['id'],
          'path': path,
        });
      }
      if (mounted) Navigator.pop(context);
    } on PostgrestException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickPhotos() async {
    final picked = await _imagePicker.pickMultiImage(imageQuality: 80);
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _photos.addAll(picked.take(3 - _photos.length));
    });
  }

  Future<void> _chooseRequestedTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _requestedAt ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _requestedAt == null
          ? TimeOfDay.now()
          : TimeOfDay.fromDateTime(_requestedAt!),
    );
    if (time == null || !mounted) return;
    setState(
      () => _requestedAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  Future<void> _chooseLocation() async {
    final location = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => MapPicker(
          initialLocation: _latitude == null
              ? null
              : LatLng(_latitude!, _longitude!),
        ),
      ),
    );
    if (location != null && mounted) {
      setState(() {
        _latitude = location.latitude;
        _longitude = location.longitude;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Solicitar un técnico')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Cuenta qué necesita reparación. Técnicos de tu zona podrán enviarte una propuesta.',
          ),
          const SizedBox(height: 22),
          DropdownButtonFormField(
            value: _category,
            decoration: const InputDecoration(
              labelText: 'Categoría',
              prefixIcon: Icon(Icons.category_outlined),
            ),
            items: const [
              'Electricidad',
              'Plomería',
              'Computadoras',
              'Celulares',
              'Electrodomésticos',
              'Otro',
            ].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => _category = v!),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _zone,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Zona o barrio',
              prefixIcon: Icon(Icons.location_on_outlined),
            ),
            validator: (v) =>
                (v == null || v.trim().length < 2) ? 'Indica tu zona' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _description,
            minLines: 4,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Describe el problema',
              alignLabelWithHint: true,
            ),
            validator: (v) => (v == null || v.trim().length < 10)
                ? 'Escribe al menos 10 caracteres'
                : null,
          ),
          const SizedBox(height: 18),
          Text(
            '¿Cuándo necesitas el servicio?',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          RadioListTile(
            value: 'normal',
            groupValue: _urgency,
            onChanged: (v) => setState(() => _urgency = v!),
            title: const Text('Puedo esperar'),
          ),
          RadioListTile(
            value: 'hoy',
            groupValue: _urgency,
            onChanged: (v) => setState(() => _urgency = v!),
            title: const Text('Lo necesito hoy'),
          ),
          RadioListTile(
            value: 'emergencia',
            groupValue: _urgency,
            onChanged: (v) => setState(() => _urgency = v!),
            title: const Text('🚨 Emergencia'),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _chooseRequestedTime,
            icon: const Icon(Icons.schedule_outlined),
            label: Text(
              _requestedAt == null
                  ? 'Elegir fecha y hora del servicio (opcional)'
                  : 'Servicio: ${_formatDateTime(context, _requestedAt!)}',
            ),
          ),
          if (_requestedAt != null)
            TextButton(
              onPressed: () => setState(() => _requestedAt = null),
              child: const Text('Lo necesito lo antes posible'),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _chooseLocation,
            icon: Icon(
              _latitude == null ? Icons.map_outlined : Icons.location_on,
            ),
            label: Text(
              _latitude == null
                  ? 'Elegir ubicación en el mapa (opcional)'
                  : 'Ubicación seleccionada',
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _photos.length >= 3 ? null : _pickPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text('Agregar fotos del problema (${_photos.length}/3)'),
          ),
          if (_photos.isNotEmpty)
            SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _LocalPhotoPreview(file: _photos[index]),
                    ),
                    Positioned(
                      right: 0,
                      child: IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        onPressed: () =>
                            setState(() => _photos.removeAt(index)),
                        icon: const Icon(Icons.close, size: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Text(_saving ? 'Publicando...' : 'Publicar solicitud'),
            ),
          ),
        ],
      ),
    ),
  );
}

class RequestDetail extends StatelessWidget {
  const RequestDetail({
    super.key,
    required this.request,
    required this.clientView,
  });
  final Map<String, dynamic> request;
  final bool clientView;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Detalle de solicitud')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          request['category'] as String,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.location_on_outlined),
            const SizedBox(width: 4),
            Text(request['zone'] as String),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          request['description'] as String,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        RequestImages(requestId: request['id'] as int),
        const SizedBox(height: 24),
        StatusChip(status: request['status'] as String),
        if (clientView) ClientServiceProgress(requestId: request['id'] as int),
        const SizedBox(height: 28),
        if (clientView)
          OffersList(
            requestId: request['id'] as int,
            requestOpen: request['status'] == 'pendiente',
          )
        else if (request['status'] == 'pendiente')
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OfferForm(
                  requestId: request['id'] as int,
                  category: request['category'] as String,
                ),
              ),
            ),
            icon: const Icon(Icons.local_offer_outlined),
            label: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Enviar una oferta'),
            ),
          ),
      ],
    ),
  );
}

class ClientServiceProgress extends StatefulWidget {
  const ClientServiceProgress({super.key, required this.requestId});
  final int requestId;

  @override
  State<ClientServiceProgress> createState() => _ClientServiceProgressState();
}

class _ClientServiceProgressState extends State<ClientServiceProgress> {
  late Future<Map<String, dynamic>> _service;

  @override
  void initState() {
    super.initState();
    _service = _load();
  }

  Future<Map<String, dynamic>> _load() => Supabase.instance.client
      .from('service_requests')
      .select('status, work_stage')
      .eq('id', widget.requestId)
      .single();

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _service,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextButton.icon(
            onPressed: () => setState(() => _service = _load()),
            icon: const Icon(Icons.refresh),
            label: const Text('Actualizar estado del servicio'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(),
        );
      }
      final stage = snapshot.data!['work_stage'] as String?;
      final (
        IconData icon,
        Color color,
        String title,
        String subtitle,
      ) = switch (stage) {
        'en_proceso' => (
          Icons.construction,
          const Color(0xFF075E54),
          'Trabajo en proceso',
          'El técnico indicó que ya está trabajando en tu solicitud.',
        ),
        'completado' => (
          Icons.check_circle,
          Colors.green,
          'Trabajo completado',
          'El servicio fue marcado como completado.',
        ),
        _ => (
          Icons.hourglass_top,
          Colors.orange,
          'Oferta aceptada',
          'El técnico coordinará contigo para iniciar el servicio.',
        ),
      };
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: color),
              title: Row(
                children: [
                  Expanded(child: Text(title)),
                  IconButton(
                    tooltip: 'Actualizar',
                    onPressed: () => setState(() => _service = _load()),
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
              subtitle: Text(subtitle),
            ),
            // El trabajo se paga cuando el técnico lo marca como completado
            if (stage == 'completado')
              PagoAlTecnico(requestId: widget.requestId),
            if (stage == 'completado')
              ReviewSection(requestId: widget.requestId),
          ],
        ),
      );
    },
  );
}

class ReviewSection extends StatefulWidget {
  const ReviewSection({super.key, required this.requestId});
  final int requestId;

  @override
  State<ReviewSection> createState() => _ReviewSectionState();
}

class _ReviewSectionState extends State<ReviewSection> {
  final _comment = TextEditingController();
  int _rating = 0;
  bool _saving = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _saveReview() async {
    if (_rating == 0) return;
    setState(() => _saving = true);
    try {
      final db = Supabase.instance.client;
      final offer = await db
          .from('offers')
          .select('technician_id')
          .eq('request_id', widget.requestId)
          .eq('status', 'aceptada')
          .single();
      await db.from('service_reviews').insert({
        'request_id': widget.requestId,
        'client_id': db.auth.currentUser!.id,
        'technician_id': offer['technician_id'],
        'rating': _rating,
        'comment': _comment.text.trim().isEmpty ? null : _comment.text.trim(),
      });
    } on PostgrestException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>?>(
    future: Supabase.instance.client
        .from('service_reviews')
        .select()
        .eq('request_id', widget.requestId)
        .maybeSingle(),
    builder: (context, snapshot) {
      final existing = snapshot.data;
      if (existing != null) {
        final stars = '★' * (existing['rating'] as int);
        return Card(
          color: Colors.amber.shade50,
          child: ListTile(
            leading: const Icon(Icons.star, color: Colors.amber),
            title: Text('$stars  ${existing['rating']}/5'),
            subtitle: Text(
              existing['comment'] as String? ??
                  'Gracias por calificar el servicio.',
            ),
          ),
        );
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '¿Cómo calificas al técnico?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Row(
                children: List.generate(
                  5,
                  (index) => IconButton(
                    onPressed: () => setState(() => _rating = index + 1),
                    icon: Icon(
                      index < _rating ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                    ),
                  ),
                ),
              ),
              TextField(
                controller: _comment,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Comentario opcional',
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saving || _rating == 0 ? null : _saveReview,
                  child: Text(_saving ? 'Guardando...' : 'Enviar calificación'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _LocalPhotoPreview extends StatelessWidget {
  const _LocalPhotoPreview({required this.file});
  final XFile file;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: file.readAsBytes(),
    builder: (context, snapshot) {
      if (!snapshot.hasData)
        return const SizedBox(
          width: 90,
          height: 90,
          child: Center(child: CircularProgressIndicator()),
        );
      return Image.memory(
        snapshot.data!,
        width: 90,
        height: 90,
        fit: BoxFit.cover,
      );
    },
  );
}

class RequestImages extends StatelessWidget {
  const RequestImages({super.key, required this.requestId});
  final int requestId;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, dynamic>>>(
        future: Supabase.instance.client
            .from('request_images')
            .select('path')
            .eq('request_id', requestId)
            .order('created_at'),
        builder: (context, snapshot) {
          if (snapshot.hasError) return const SizedBox.shrink();
          if (!snapshot.hasData)
            return const SizedBox(
              height: 60,
              child: Center(child: CircularProgressIndicator()),
            );
          final images = snapshot.data!;
          if (images.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Fotos del problema',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 150,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, index) => _StoredRequestImage(
                    path: images[index]['path'] as String,
                  ),
                ),
              ),
            ],
          );
        },
      );
}

class _StoredRequestImage extends StatelessWidget {
  const _StoredRequestImage({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: Supabase.instance.client.storage
        .from('request-media')
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

class OffersList extends StatefulWidget {
  const OffersList({
    super.key,
    required this.requestId,
    required this.requestOpen,
  });
  final int requestId;
  final bool requestOpen;
  @override
  State<OffersList> createState() => _OffersListState();
}

class _OffersListState extends State<OffersList> {
  bool _accepting = false;
  bool _accepted = false;
  @override
  Widget build(BuildContext context) =>
      StreamBuilder<List<Map<String, dynamic>>>(
        stream: Supabase.instance.client
            .from('offers')
            .stream(primaryKey: ['id'])
            .eq('request_id', widget.requestId)
            .order('created_at'),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const LoadError(
              message: 'No se pudieron cargar las ofertas. Vuelve a abrir la solicitud para reintentar.',
            );
          }
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final offers = snapshot.data!;
          if (offers.isEmpty)
            return const EmptyState(
              icon: Icons.hourglass_empty_rounded,
              title: 'Aún no hay ofertas',
              subtitle: 'Te avisaremos cuando un técnico responda.',
            );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ofertas recibidas',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ...offers.map(
                (o) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.engineering_outlined),
                            const SizedBox(width: 8),
                            OfferTechnicianName(
                              technicianId: o['technician_id'] as String,
                            ),
                            StatusChip(status: o['status'] as String),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Bs ${o['price']}',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: const Color(0xFF075E54),
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        Text(o['message'] as String),
                        TextButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => TechnicianProfile(
                                technicianId: o['technician_id'] as String,
                                editable: false,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.person_outline),
                          label: const Text('Ver perfil del técnico'),
                        ),
                        if (o['status'] == 'aceptada')
                          TechnicianWhatsAppContact(
                            technicianId: o['technician_id'] as String,
                          ),
                        if (widget.requestOpen &&
                            !_accepted &&
                            o['status'] == 'pendiente')
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _accepting
                                  ? null
                                  : () => _accept(context, o['id'] as int),
                              child: const Text('Aceptar oferta'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
  Future<void> _accept(BuildContext context, int offerId) async {
    if (_accepting || _accepted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Aceptar esta oferta?'),
        content: const Text(
          'Se asignará el trabajo a este técnico y se rechazarán las otras ofertas de la solicitud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Aceptar oferta'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _accepting || _accepted) return;
    setState(() => _accepting = true);
    try {
      final db = Supabase.instance.client;
      await db.rpc('accept_offer', params: {'p_offer_id': offerId});
      if (mounted) {
        setState(() => _accepted = true);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Oferta aceptada. Ya puedes coordinar con el técnico.',
            ),
          ),
        );
      }
    } on PostgrestException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo confirmar la oferta. Revisa tu conexión y vuelve a abrir la solicitud para comprobar su estado.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }
}

class OfferTechnicianName extends StatelessWidget {
  const OfferTechnicianName({super.key, required this.technicianId});
  final String technicianId;

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: Supabase.instance.client
        .from('profiles')
        .select('full_name, verification_status')
        .eq('id', technicianId)
        .single(),
    builder: (context, snapshot) {
      final name = snapshot.data?['full_name'] as String? ?? 'Técnico';
      final verified = snapshot.data?['verification_status'] == 'verificado';
      return Expanded(
        child: Row(
          children: [
            Flexible(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (verified)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.verified, color: Colors.green, size: 18),
              ),
          ],
        ),
      );
    },
  );
}

class TechnicianWhatsAppContact extends StatelessWidget {
  const TechnicianWhatsAppContact({super.key, required this.technicianId});
  final String technicianId;

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: Supabase.instance.client
        .from('profiles')
        .select('full_name, phone')
        .eq('id', technicianId)
        .single(),
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const SizedBox.shrink();
      final technician = snapshot.data!;
      final phone = (technician['phone'] as String? ?? '').replaceAll(
        RegExp(r'\D'),
        '',
      );
      if (phone.isEmpty) {
        return const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('El técnico aún no registró su WhatsApp.'),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: FilledButton.icon(
          onPressed: () => _openWhatsApp(context, phone),
          icon: const Icon(Icons.chat_outlined),
          label: Text('Contactar a ${technician['full_name']}'),
        ),
      );
    },
  );

  Future<void> _openWhatsApp(BuildContext context, String phone) async {
    final text = Uri.encodeComponent(
      'Hola, acepté tu oferta en ArreglaYa. ¿Podemos coordinar el servicio?',
    );
    final opened = await launchUrl(
      Uri.parse('https://wa.me/$phone?text=$text'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
      );
    }
  }
}

class OfferForm extends StatefulWidget {
  const OfferForm({super.key, required this.requestId, required this.category});
  final int requestId;
  final String category;
  @override
  State<OfferForm> createState() => _OfferFormState();
}

class _OfferFormState extends State<OfferForm> {
  final _form = GlobalKey<FormState>();
  final _price = TextEditingController();
  final _message = TextEditingController();
  bool _saving = false;
  @override
  void dispose() {
    _price.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('offers').insert({
        'request_id': widget.requestId,
        'technician_id': Supabase.instance.client.auth.currentUser!.id,
        'price': num.parse(_price.text),
        'message': _message.text.trim(),
      });
      if (mounted) Navigator.pop(context);
    } on PostgrestException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Enviar oferta')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Servicio: ${widget.category}'),
          const SizedBox(height: 20),
          TextFormField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Precio estimado (Bs)',
              prefixIcon: Icon(Icons.payments_outlined),
            ),
            validator: (v) => num.tryParse(v ?? '') == null
                ? 'Ingresa un precio válido'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _message,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Mensaje para el cliente',
              alignLabelWithHint: true,
            ),
            validator: (v) =>
                (v ?? '').trim().length < 3 ? 'Escribe un mensaje breve' : null,
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _saving ? null : _send,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Text(_saving ? 'Enviando...' : 'Enviar oferta'),
            ),
          ),
        ],
      ),
    ),
  );
}
