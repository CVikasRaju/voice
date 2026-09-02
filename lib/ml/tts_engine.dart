import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// Offline text-to-speech back end.
///
/// CURRENT: Uses the platform synthesizer (fully on-device on Android).
/// This works for all 10 supported languages — Android ships with Indic
/// language TTS voices in most OEM builds.
class TtsEngine {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;
  String? _currentBcp47;

  /// Configure the engine for the given BCP 47 locale.
  /// No-op if already configured for the same locale.
  Future<void> configure(String bcp47, {required double speechRate}) async {
    if (_configured && _currentBcp47 == bcp47) return;

    await _tts.setLanguage(bcp47);
    await _tts.setSpeechRate(speechRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _currentBcp47 = bcp47;
    _configured = true;
  }

  /// Speak [text] aloud.
  ///
  /// When [emergency] is true, volume is forced to maximum and routed to
  /// the alarm stream (ARCHITECTURE.md §2.3). This requires the
  /// MODIFY_AUDIO_SETTINGS permission.
  Future<void> speak(String text, {bool emergency = false}) async {
    if (text.isEmpty) return;

    if (emergency) {
      await _tts.setVolume(1.0);
      await _tts.setSpeechRate(1.1); // slightly faster for urgency
    }

    await _tts.speak(text);
    await _tts.awaitSpeakCompletion(true);

    if (emergency) {
      await _tts.setVolume(0.8);
      await _tts.setSpeechRate(0.9);
    }
  }

  /// Whether the engine has been configured.
  bool get isConfigured => _configured;

  /// Stop any ongoing speech.
  Future<void> stop() async {
    await _tts.stop();
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await _tts.stop();
    _configured = false;
  }
}
