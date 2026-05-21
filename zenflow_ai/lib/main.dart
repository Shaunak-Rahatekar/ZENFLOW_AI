import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // TODO: Replace with actual Supabase URL and Anon Key during configuration sprint
  await Supabase.initialize(
    url: 'https://YOUR_SUPABASE_URL.supabase.co',
    anonKey: 'YOUR_SUPABASE_ANON_KEY',
  );

  runApp(
    const ProviderScope(
      child: ZenFlowApp(),
    ),
  );
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
      home: const Scaffold(
        body: Center(
          child: Text('ZenFlow AI Environment Ready'),
        ),
      ),
    );
  }
}
