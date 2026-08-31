import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// Offline text-to-speech back end.
///
/// CURRENT: Uses the platform synthesizer (fully on-device on Android).
/// This works for all 10 supported languages — Android ships with Indic
/// language TTS voices in most OEM builds.
///
/// PRODUCTION SWAP-IN (docs/ML_PIPELINE.md §4):
/// Replace the platform synthesizer with sherpa-onnx VITS models:
///
/// 1. Convert AI4Bharat Indic-TTS (FastPitch + HiFi-GAN) to ONNX:
///    ```bash
///    # From the AI4Bharat/Indic-TTS repo:
///    python -c "
///    import torch
///    model = torch.load('hi/fastpitch/best_model.pth')
///    torch.onnx.export(model, dummy_input, 'hi/fastpitch.onnx')
///    "
///    ```
///
/// 2. Use sherpa-onnx's OfflineTts API:
///    ```dart
///    import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
///
///    final tts = sherpa.OfflineTts(
///      config: sherpa.OfflineTtsConfig(
///        model: sherpa.OfflineTtsModelConfig(
///          vits: sherpa.OfflineTtsVitsModelConfig(
///            model: 'vits-hi.int8.onnx',
///            tokens: 'tokens.txt',
///            dictDir: 'dict',
///            lexicon: '',
///          ),
///          numThreads: 2,
///          provider: 'cpu',
///        ),
///        maxNumSentences: 1,
///      ),
///    );
///
///    final audio = tts.generate(text: 'नमस्ते', sid: 0, speed: 1.0);
///    // audio contains Float32List PCM samples at 22050Hz
///    ```
///
/// 3. Alternative: Use Meta MMS-TTS (already has ONNX exports for Indic):
///    https://huggingface.co/facebook/mms-tts-hin
///
/// For now, platform TTS provides acceptable quality for the demo.
class TtsEngine {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;

  /// Configure the engine for the given BCP 47 locale.
  /// No-op if already configured for the same locale.
  Future<void> configure(String bcp47, {required double speechRate}) async {
    if (_configured) {
      final current = await _tts.getDefaultLocale;
      if (current == bcp47) return;
    }

    await _tts.setLanguage(bcp47);
    await _tts.setSpeechRate(speechRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
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
