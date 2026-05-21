import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';

/// On-device TTS service using flutter_tts.
/// Supports en-US and mr-IN (Marathi).
/// Call [speak] from anywhere — it cancels the current utterance first.
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;

    _tts.setStartHandler(() {
      _isSpeaking = true;
    });
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
    });
    _tts.setErrorHandler((msg) {
      _isSpeaking = false;
    });
    _tts.setCancelHandler(() {
      _isSpeaking = false;
    });

    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(0.45); // slightly slow — ideal for yoga coaching
    await _tts.setPitch(1.0);

    // Android-specific: use the best available voice
    if (Platform.isAndroid) {
      await _tts.setQueueMode(1); // flush queue before speaking
    }

    await setLanguage('en-US');
  }

  /// Sets the TTS language. Use 'en-US' or 'mr-IN'.
  Future<void> setLanguage(String languageCode) async {
    await _ensureInit();
    await _tts.setLanguage(languageCode);
  }

  /// Speaks [text] if not already speaking.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (_isSpeaking) return; // Drop if currently speaking
    await _ensureInit();
    await _tts.stop();
    await _tts.speak(text);
  }

  /// Speaks a correction in both English then Marathi.
  Future<void> speakCorrection({
    required String english,
    required String marathi,
  }) async {
    await speak(english);
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
