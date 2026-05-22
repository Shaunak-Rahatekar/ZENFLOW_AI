import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cloud TTS service using Deepgram Aura via Supabase Edge Function.
/// Call [speak] from anywhere — it interrupts the current utterance.
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final AudioPlayer _audioPlayer = AudioPlayer();

  static const int _cooldownMs = 4000;
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Text sanitisation ───────────────────────────────────────────────────────
  /// Strips markdown and formatting characters so TTS never reads symbols aloud.
  static String sanitise(String raw) {
    var text = raw;

    // Remove markdown headings: ### Title → Title
    text = text.replaceAll(RegExp(r'#{1,6}\s*'), '');

    // Remove bold/italic markers: **text** → text, *text* → text, __text__ → text
    text = text.replaceAll(RegExp(r'\*{1,3}'), '');
    text = text.replaceAll(RegExp(r'_{1,3}'), '');

    // Remove horizontal rules: --- or ___ or ***
    text = text.replaceAll(RegExp(r'^[-_*]{3,}\s*$', multiLine: true), '');

    // Remove inline code and code blocks: `code` → code
    text = text.replaceAll(RegExp(r'`{1,3}[^`]*`{1,3}'), '');

    // Remove links: [text](url) → text
    text = text.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');

    // Remove image syntax: ![alt](url) → ''
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '');

    // Remove blockquote markers: > text → text
    text = text.replaceAll(RegExp(r'^\s*>\s*', multiLine: true), '');

    // Remove bullet/list markers: - item or * item or 1. item → item
    text = text.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');

    // Remove HTML tags: <br>, <b>, etc.
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');

    // Remove brackets and braces: [] {} ()
    text = text.replaceAll(RegExp(r'[[\]{}()]'), '');

    // Remove pipe characters (table syntax)
    text = text.replaceAll('|', ' ');

    // Remove backtick remnants
    text = text.replaceAll('`', '');

    // Collapse multiple spaces/newlines into a single space
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Ensure sentences end with punctuation for natural TTS pacing
    if (text.isNotEmpty && !'.!?'.contains(text[text.length - 1])) {
      text = '$text.';
    }

    return text;
  }

  Future<void> setLanguage(String languageCode) async {
    // No-op for cloud TTS. Could be used to switch Deepgram models in the future.
  }

  /// Speaks [text] after sanitising it.
  /// Respects a [_cooldownMs] cooldown so rapid corrections are dropped,
  /// unless [bypassCooldown] is true.
  Future<void> speak(String text, {bool bypassCooldown = false}) async {
    final clean = sanitise(text);
    if (clean.isEmpty || clean == '.') return;

    final now = DateTime.now();
    if (!bypassCooldown && now.difference(_lastSpokenAt).inMilliseconds < _cooldownMs) return;
    _lastSpokenAt = now;

    await _audioPlayer.stop();

    try {
      final supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
      final url = Uri.parse('$supabaseUrl/functions/v1/tts');
      final request = await HttpClient().postUrl(url);
      
      final session = Supabase.instance.client.auth.currentSession;
      final authKey = session != null ? session.accessToken : (dotenv.env['SUPABASE_ANON_KEY'] ?? '');
      request.headers.add('Authorization', 'Bearer $authKey');
      request.headers.add('Content-Type', 'application/json');
      request.write(jsonEncode({'text': clean, 'voice': 'aura-asteria-en'}));
      
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytes = await consolidateHttpClientResponseBytes(response);
        await _audioPlayer.play(BytesSource(bytes));
      } else {
        final error = await response.transform(utf8.decoder).join();
        debugPrint('[TTS] Edge Function Error ${response.statusCode}: $error');
      }
    } catch (e) {
      debugPrint('[TTS] Error generating/playing audio: $e');
    }
  }

  Future<void> speakCorrection({
    required String english,
    required String marathi,
  }) async {
    // Interruption is fine for corrections
    await speak('Wait. $english');
  }

  Future<void> speakGreeting(String poseName) async {
    await speak("Welcome to your ZenFlow session. Let's begin with your first pose: $poseName. Get into position.", bypassCooldown: true);
  }

  Future<void> speakNextPose(String poseName, String orientation) async {
    final orientationText = orientation == 'side' ? 'Please stand sideways to the camera.' : 'Please face the camera directly.';
    await speak("Next up is $poseName. $orientationText", bypassCooldown: true);
  }

  Future<void> speakMotivation() async {
    final motivations = [
      "You are doing great, hold just a little more time.",
      "Perfect form. Keep breathing.",
      "Doing excellent, maintain your balance.",
    ];
    motivations.shuffle();
    // Only speak motivation if we haven't spoken recently (respect cooldown)
    await speak(motivations.first);
  }

  Future<void> speakCompletion() async {
    await speak("Workout complete. Thank you for practicing today, see you tomorrow!", bypassCooldown: true);
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
  }

  Future<void> dispose() async {
    await _audioPlayer.dispose();
  }
}
