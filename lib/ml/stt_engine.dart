import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'languages.dart';

typedef SttResultCallback = void Function(String text, bool isFinal);

/// Offline speech-to-text engine using sherpa-onnx with AI4Bharat
/// IndicConformer INT8 ONNX models.
///
/// Architecture (docs/ML_PIPELINE.md §1, §3, §4):
/// - Model: AI4Bharat IndicConformer (NeMo CTC), INT8 quantized
/// - Runtime: sherpa-onnx (C++ core via Dart FFI)
/// - Input: 16kHz mono PCM from device microphone
/// - Output: transcribed text in the selected Indic language
///
/// Model files are downloaded to the app's documents directory on first
/// launch. See scripts/fetch_models.py for the download URLs.
class SttEngine {
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  sherpa.VadModelConfig? _vadConfig;
  AudioRecorder? _recorder;
  bool _initialized = false;
  String? _currentLocale;
  StreamSubscription<Uint8List>? _audioSubscription;

  /// Initialize the recognizer for the given language.
  ///
  /// Models are loaded from the app's documents directory.
  /// If models don't exist yet, falls back to platform STT.
  Future<void> init(Lang lang) async {
    if (_initialized && _currentLocale == lang.code) return;

    // Dispose previous recognizer if switching languages.
    if (_recognizer != null) {
      _recognizer!.free();
      _recognizer = null;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelPath = '${appDir.path}/${lang.sttModel}';
      final tokensPath = '${appDir.path}/${lang.sttTokens}';

      // Check if model files exist.
      if (!await File(modelPath).exists() ||
          !await File(tokensPath).exists()) {
        // Models not downloaded yet — caller should trigger download.
        _initialized = false;
        return;
      }

      // Configure Silero VAD for endpoint detection.
      _vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          threshold: 0.5,
          minSilenceDuration: 0.6, // 600ms silence = utterance boundary
          minSpeechDuration: 0.25,
          maxSpeechDuration: 30.0,
        ),
        numThreads: 2,
        provider: 'cpu',
      );

      _vad = sherpa.VoiceActivityDetector(
        config: _vadConfig!,
        bufferSizeInSeconds: 30.0,
      );

      // Configure NeMo CTC recognizer (AI4Bharat IndicConformer).
      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
              model: modelPath,
            ),
            tokens: tokensPath,
            numThreads: 2,
            provider: 'cpu',
            debug: false,
          ),
          lm: const sherpa.OfflineLMConfig(
            model: '',
            scale: 0.1,
          ),
          decodingMethod: 'greedy_search',
          maxActivePaths: 1,
          hotwordsFile: '',
          hotwordsScore: 1.5,
          ruleFsts: '',
          ruleFars: '',
        ),
      );

      _currentLocale = lang.code;
      _initialized = true;
    } catch (e) {
      // Model loading failed — fall back to platform STT.
      _initialized = false;
      _recognizer = null;
    }
  }

  /// Start listening and transcribing.
  ///
  /// Records 16kHz mono PCM from the microphone and feeds it to the
  /// sherpa-onnx recognizer in chunks.
  Future<void> start({
    required String localeId,
    required SttResultCallback onResult,
  }) async {
    // Find the Lang for this localeId.
    final lang = kLanguages.firstWhere(
      (l) => l.code == localeId,
      orElse: () => kEnglish,
    );

    if (!_initialized || _currentLocale != localeId) {
      await init(lang);
    }

    if (!_initialized || _recognizer == null) {
      // Models not available — cannot transcribe offline.
      onResult('[Offline models not installed]', true);
      return;
    }

    // Start recording.
    _recorder = AudioRecorder();
    if (await _recorder!.hasPermission()) {
      final stream = await _recorder!.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      // Feed audio chunks to the recognizer.
      _audioSubscription = stream.listen((audioData) {
        _processAudio(audioData, onResult);
      });
    }
  }

  /// Process a chunk of PCM audio through the recognizer.
  void _processAudio(Uint8List pcmData, SttResultCallback onResult) {
    if (_recognizer == null || _vad == null) return;

    // Convert int16 PCM to float32 for sherpa-onnx.
    final float32Data = _pcm16ToFloat32(pcmData);

    // Feed to VAD for endpoint detection.
    _vad!.acceptWaveform(float32Data);

    // Check if we have a complete speech segment.
    while (_vad!.isDetected()) {
      final segment = _vad!.front();
      if (segment.samples.isNotEmpty) {
        // We have a speech segment — feed to recognizer.
        final stream = _recognizer!.createStream();
        stream.acceptWaveform(
          sampleRate: 16000,
          samples: segment.samples,
        );
        _recognizer!.decode(stream);

        final result = _recognizer!.getResult(stream);
        if (result.text.isNotEmpty) {
          onResult(result.text, true); // Final result
        }
        stream.free();
      }

      _vad!.pop();
    }
  }

  /// Convert int16 PCM bytes to float32 array.
  Float32List _pcm16ToFloat32(Uint8List pcmBytes) {
    final int16View = Int16List.view(pcmBytes.buffer);
    final float32List = Float32List(int16View.length);
    for (var i = 0; i < int16View.length; i++) {
      float32List[i] = int16View[i] / 32768.0;
    }
    return float32List;
  }

  /// Stop listening.
  Future<void> stop() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _recorder?.stop();
    _recorder = null;
  }

  /// Whether the engine is currently listening.
  bool get isListening => _recorder != null;

  /// Whether the offline models are loaded and ready.
  bool get isReady => _initialized && _recognizer != null;

  /// Current locale.
  String? get currentLocale => _currentLocale;

  /// Dispose resources.
  Future<void> dispose() async {
    await stop();
    _recognizer?.free();
    _recognizer = null;
    _vad?.free();
    _vad = null;
    _initialized = false;
  }
}
