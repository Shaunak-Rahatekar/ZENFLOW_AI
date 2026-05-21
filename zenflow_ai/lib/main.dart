import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zenflow_ai/core/shell/app_shell.dart';
import 'package:zenflow_ai/features/auth/screens/auth_screen.dart';
import 'package:zenflow_ai/features/auth/screens/profile_screen.dart';
import 'package:zenflow_ai/features/auth/providers/profile_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Failed to load .env file: $e");
  }

  // Credentials are injected via --dart-define at build/run time.
  // The fallback reads from the .env file
  const envSupabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );
  const envSupabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  final supabaseUrl = envSupabaseUrl.isNotEmpty ? envSupabaseUrl : dotenv.env['SUPABASE_URL'] ?? '';
  final supabaseAnonKey = envSupabaseAnonKey.isNotEmpty ? envSupabaseAnonKey : dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  bool initSuccess = true;
  String errorMessage = '';

  try {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw Exception('Missing Supabase URL or Anon Key in environment variables.');
    }
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  } catch (e) {
    initSuccess = false;
    errorMessage = e.toString();
  }

  runApp(
    ProviderScope(
      child: initSuccess 
          ? const ZenFlowApp() 
          : ConnectionErrorApp(message: errorMessage),
    ),
  );
}

class ConnectionErrorApp extends StatelessWidget {
  final String message;
  const ConnectionErrorApp({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 64),
                const SizedBox(height: 24),
                Text(
                  'Connection Error',
                  style: GoogleFonts.inter(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 16),
                Text(
                  'Could not connect to Supabase. Check your --dart-define keys.\n\nError: $message',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ZenFlowApp extends StatelessWidget {
  const ZenFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZenFlow AI',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(),
      ),
      themeMode: ThemeMode.system,
      home: const AuthGuard(),
    );
  }
}

class AuthGuard extends ConsumerStatefulWidget {
  const AuthGuard({super.key});

  @override
  ConsumerState<AuthGuard> createState() => _AuthGuardState();
}

class _AuthGuardState extends ConsumerState<AuthGuard> {
  late final StreamSubscription<AuthState> _authStateSubscription;

  @override
  void initState() {
    super.initState();
    _authStateSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (mounted) {
        ref.invalidate(profileProvider);
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _authStateSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = Supabase.instance.client.auth.currentSession;

    if (session == null) return const AuthScreen();

    final profileAsync = ref.watch(profileProvider);

    return profileAsync.when(
      data: (profile) {
        final incomplete = profile == null ||
            (profile.name ?? '').isEmpty && (profile.fitnessGoal ?? '').isEmpty;

        if (incomplete) return const ProfileScreen();
        return const AppShell();
      },
      loading: () => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.teal),
              const SizedBox(height: 20),
              Text(
                'Syncing with Cloud...',
                style: GoogleFonts.inter(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
      error: (e, st) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'Error loading profile',
            style: GoogleFonts.inter(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
