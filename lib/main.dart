import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/api.dart';
import 'core/shift_tracker.dart';
import 'screens/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureShiftService();
  runApp(const AtsApp());
}

class AtsApp extends StatefulWidget {
  const AtsApp({super.key});
  @override
  State<AtsApp> createState() => _AtsAppState();
}

class _AtsAppState extends State<AtsApp> {
  final session = AtsSession();
  ThemeMode themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    session.addListener(_refresh);
    _initialize();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == prefs.getString('theme_mode'),
      orElse: () => ThemeMode.system,
    );
    if (mounted) setState(() {});
    await session.initialize();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _setTheme(ThemeMode value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', value.name);
    setState(() => themeMode = value);
  }

  @override
  void dispose() {
    session.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFB3222A);
    return MaterialApp(
      title: 'ATS Técnicos',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed),
          useMaterial3: true),
      darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: seed, brightness: Brightness.dark),
          useMaterial3: true),
      home: !session.initialized
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session.signedIn
              ? HomeScreen(
                  session: session,
                  themeMode: themeMode,
                  onThemeChanged: _setTheme)
              : LoginScreen(session: session),
    );
  }
}

class LoginScreen extends StatefulWidget {
  final AtsSession session;
  const LoginScreen({super.key, required this.session});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.login(email.text, password.text);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _biometric() async {
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.session.unlockBiometric();
    if (mounted) {
      setState(() {
        busy = false;
        if (!result) {
          error =
              'No se pudo validar tu huella o renovar la sesión. Ingresa con contraseña.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: SafeArea(
            child: Center(
                child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Image.asset('assets/images/ats-logo.png',
                  height: 92, fit: BoxFit.contain),
              const SizedBox(height: 30),
              Text('Servicio técnico',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('Ingresa para atender tus órdenes asignadas.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 30),
              TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'Correo', border: OutlineInputBorder())),
              const SizedBox(height: 14),
              TextField(
                  controller: password,
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                  decoration: const InputDecoration(
                      labelText: 'Contraseña', border: OutlineInputBorder())),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 18),
              FilledButton(
                  onPressed: busy ? null : _login, child: const Text('Entrar')),
              if (widget.session.canUnlock)
                TextButton.icon(
                    onPressed: busy ? null : _biometric,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Entrar con biometría')),
              if (widget.session.canRestore)
                TextButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              await widget.session.restore();
                            } catch (e) {
                              if (mounted) setState(() => error = e.toString());
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    icon: const Icon(Icons.sync),
                    label: const Text('Reintentar sesión guardada')),
              if (busy)
                const Padding(
                    padding: EdgeInsets.all(14),
                    child: Center(child: CircularProgressIndicator())),
            ],
          )),
    ))));
  }
}
