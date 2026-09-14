import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'languages.dart';
import 'model_downloader.dart';

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

  /// Speech text accumulated during the current PTT hold. The VAD only
  /// emits a segment once it has seen enough trailing silence, so a short
  /// utterance spoken right before the button is released would otherwise
  /// be lost. Every finalized VAD segment appends here, and stop() flushes
  /// whatever the VAD still holds so nothing is dropped.
  String _utterance = '';

  // ── Model download state ──────────────────────────────────────
  bool _downloading = false;
  double _downloadProgress = 0.0;
  String? _downloadingLang;

  /// Whether a model download is currently in progress.
  bool get isDownloading => _downloading;

  /// Current download progress (0.0–1.0).
  double get downloadProgress => _downloadProgress;

  /// Language code currently being downloaded, if any.
  String? get downloadingLang => _downloadingLang;

  /// Check if models are available for [lang] (without initializing).
  Future<bool> hasModels(Lang lang) async {
    await _ensureBundledModel(lang);
    return ModelDownloader.areModelsAvailable(lang);
  }

  /// Ensure models are downloaded for [lang], then initialize the recognizer.
  ///
  /// Downloads models from HuggingFace if not already present.
  /// Returns `true` if models are ready, `false` if download failed.
  Future<bool> prepareModels(
    Lang lang, {
    DownloadProgressCallback? onProgress,
  }) async {
    await _ensureBundledModel(lang);
    if (await ModelDownloader.areModelsAvailable(lang)) {
      return true;
    }

    _downloading = true;
    _downloadProgress = 0.0;
    _downloadingLang = lang.code;

    final success = await ModelDownloader.downloadModels(
      lang,
      onProgress: (progress) {
        _downloadProgress = progress;
        onProgress?.call(progress);
      },
    );

    _downloading = false;
    _downloadProgress = 0.0;
    _downloadingLang = null;

    return success;
  }

  /// Copy bundled asset models (e.g. Hindi) into app documents directory if present.
  Future<void> _ensureBundledModel(Lang lang) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelFile = File('${appDir.path}/${lang.sttModel}');
      final tokensFile = File('${appDir.path}/${lang.sttTokens}');

      if (!await modelFile.exists() || await modelFile.length() < 50000000) {
        try {
          final byteData = await rootBundle.load('assets/${lang.sttModel}');
          await modelFile.parent.create(recursive: true);
          await modelFile.writeAsBytes(byteData.buffer.asUint8List(
              byteData.offsetInBytes, byteData.lengthInBytes));
        } catch (_) {
          // Model not bundled in assets — will be downloaded dynamically if needed.
        }
      }

      if (!await tokensFile.exists() || await tokensFile.length() < 1000) {
        try {
          final byteData = await rootBundle.load('assets/${lang.sttTokens}');
          await tokensFile.parent.create(recursive: true);
          await tokensFile.writeAsBytes(byteData.buffer.asUint8List(
              byteData.offsetInBytes, byteData.lengthInBytes));
        } catch (_) {
          // Tokens not bundled in assets.
        }
      }
    } catch (_) {}
  }

  /// Copy VAD asset from Flutter bundle into app documents directory.
  Future<String?> _ensureVadModel() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final vadPath = '${appDir.path}/silero_vad.onnx';
      if (!await File(vadPath).exists()) {
        final byteData =
            await rootBundle.load('assets/models/vad/silero_vad.onnx');
        await File(vadPath).writeAsBytes(byteData.buffer.asUint8List(
            byteData.offsetInBytes, byteData.lengthInBytes));
      }
      return vadPath;
    } catch (e) {
      debugPrint('[SttEngine] VAD asset copy failed: $e');
      return null;
    }
  }

  /// Initialize the VAD only (no STT model required).
  Future<bool> initVad() async {
    if (_vad != null) return true;
    try {
      final vadPath = await _ensureVadModel();
      if (vadPath == null) return false;

      // NOTE (sherpa-onnx VAD constraints):
      // - maxSpeechDuration MUST be well under bufferSizeInSeconds, or the
      //   detector throws / drops segments. 20s max speech inside a 60s
      //   buffer leaves ample headroom.
      // - windowSize 512 is the silero-vad v4 default (matches the bundled
      //   silero_vad.onnx asset).
      _vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          threshold: 0.5,
          minSilenceDuration: 0.45,
          minSpeechDuration: 0.2,
          windowSize: 512,
          maxSpeechDuration: 20.0,
        ),
        sampleRate: 16000,
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      );

      _vad = sherpa.VoiceActivityDetector(
        config: _vadConfig!,
        bufferSizeInSeconds: 60.0,
      );
      return true;
    } catch (e) {
      debugPrint('[SttEngine] VAD init failed: $e');
      _vad = null;
      return false;
    }
  }

  /// Initialize the recognizer for the given language.
  ///
  /// Returns null on success, or an error string describing what failed.
  Future<String?> init(Lang lang) async {
    if (_initialized && _currentLocale == lang.code) return null;

    if (_recognizer != null) {
      _recognizer!.free();
      _recognizer = null;
    }

    await initVad();
    await _ensureBundledModel(lang);

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelPath = '${appDir.path}/${lang.sttModel}';
      final tokensPath = '${appDir.path}/${lang.sttTokens}';

      if (!await File(modelPath).exists() ||
          !await File(tokensPath).exists()) {
        _initialized = false;
        return 'model files missing on disk';
      }

      final modelSize = await File(modelPath).length();
      final tokensSize = await File(tokensPath).length();
      if (modelSize < 1000000) {
        try {
          await File(modelPath).delete();
        } catch (_) {}
        _initialized = false;
        return 'model file incomplete ($modelSize bytes) — please retry download';
      }
      if (tokensSize == 0) {
        try {
          await File(tokensPath).delete();
        } catch (_) {}
        _initialized = false;
        return 'tokens file is empty — please retry download';
      }

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
          decodingMethod: 'greedy_search',
        ),
      );

      _currentLocale = lang.code;
      _initialized = true;
      return null;
    } catch (e, stack) {
      debugPrint('[SttEngine] OfflineRecognizer init failed: $e');
      debugPrint('[SttEngine] Stack: $stack');
      _initialized = false;
      _recognizer = null;
      return e.toString();
    }
  }

  /// Start listening and transcribing.
  ///
  /// Records 16kHz mono PCM from the microphone, detects speech with
  /// Silero VAD, and runs the offline recognizer on each complete speech
  /// segment. Live transcripts stream to [onResult] while the button is
  /// held; [stop] flushes the trailing segment so short utterances are
  /// never lost.
  Future<void> start({
    required String localeId,
    required SttResultCallback onResult,
  }) async {
    final lang = kLanguages.firstWhere(
      (l) => l.code == localeId,
      orElse: () => kEnglish,
    );

    await initVad();

    if (!_initialized || _currentLocale != localeId) {
      await init(lang);
    }

    if (!_initialized || _recognizer == null) {
      onResult('Downloading offline models…', false);

      final ready = await prepareModels(lang, onProgress: (progress) {
        onResult(
          'Downloading models… ${(progress * 100).toInt()}%',
          false,
        );
      });

      if (!ready) {
        onResult('Model download failed — check internet connection', false);
        return;
      }

      final initErr = await init(lang);
      if (!_initialized || _recognizer == null) {
        onResult('Model load error: ${initErr ?? "unknown"}', false);
        return;
      }
    }

    // Ensure mic permission, then start recording.
    _recorder = AudioRecorder();
    bool hasPerm;
    try {
      hasPerm = await _recorder!.hasPermission();
    } catch (e) {
      debugPrint('[SttEngine] hasPermission threw: $e');
      hasPerm = false;
    }
    if (!hasPerm) {
      onResult('Microphone permission denied', false);
      _recorder = null;
      return;
    }

    _utterance = '';

    Stream<Uint8List> stream;
    try {
      stream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
    } catch (e) {
      debugPrint('[SttEngine] startStream failed: $e');
      onResult('Mic start failed: $e', false);
      _recorder = null;
      return;
    }

    _audioSubscription = stream.listen(
      (audioData) => _processAudio(audioData, onResult),
      onError: (Object e) {
        debugPrint('[SttEngine] audio stream error: $e');
      },
    );
  }

  /// Process a chunk of PCM audio through the VAD + recognizer.
  void _processAudio(Uint8List pcmData, SttResultCallback onResult) {
    if (pcmData.isEmpty) return;
    final float32Data = _pcm16ToFloat32(pcmData);
    final vad = _vad;

    try {
      if (vad != null) {
        vad.acceptWaveform(float32Data);
        // Drain every complete speech segment. A segment only becomes
        // available after `minSilenceDuration` of trailing silence, so
        // while the user is still talking this loop simply does nothing.
        while (!vad.isEmpty() && vad.isDetected()) {
          final segment = vad.front();
          if (segment.samples.isNotEmpty) {
            final text = _recognize(segment.samples);
            if (text.isNotEmpty) {
              _utterance =
                  _utterance.isEmpty ? text : '$_utterance $text';
              // Live preview while the button is still held.
              onResult(_utterance, false);
            }
          }
          vad.pop();
        }
      } else {
        // No VAD — recognize fixed 2s windows directly.
        final text = _recognize(float32Data);
        if (text.isNotEmpty) {
          _utterance = _utterance.isEmpty ? text : '$_utterance $text';
          onResult(_utterance, false);
        }
      }
    } catch (e) {
      debugPrint('[SttEngine] _processAudio error: $e');
    }
  }

  /// Run the offline recognizer on [samples]; returns text ('' when silent).
  String _recognize(Float32List samples) {
    final recognizer = _recognizer;
    if (recognizer == null || samples.isEmpty) return '';

    try {
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final result = recognizer.getResult(stream);
      stream.free();
      return result.text.trim();
    } catch (e) {
      debugPrint('[SttEngine] recognize error: $e');
      return '';
    }
  }

  /// Flush any speech the VAD still holds (utterance tail) and return
  /// the complete transcript for this PTT hold.
  ///
  /// Without this, a sentence spoken with less than `minSilenceDuration`
  /// of trailing silence before the button is released is discarded —
  /// the single most common cause of "the app heard nothing".
  String flushTail() {
    final vad = _vad;
    try {
      if (vad != null && !vad.isEmpty() && vad.isDetected()) {
        final segment = vad.front();
        if (segment.samples.isNotEmpty) {
          final text = _recognize(segment.samples);
          if (text.isNotEmpty) {
            _utterance = _utterance.isEmpty ? text : '$_utterance $text';
          }
        }
        vad.pop();
      }
      // Reset the VAD buffer so the next hold starts clean; leftover
      // trailing silence must not merge into the next utterance.
      vad?.clear();
    } catch (e) {
      debugPrint('[SttEngine] flushTail error: $e');
    }
    final text = _utterance;
    _utterance = '';
    return text;
  }

  /// Convert int16 PCM bytes to float32 array.
  Float32List _pcm16ToFloat32(Uint8List pcmBytes) {
    if (pcmBytes.length % 2 != 0) {
      pcmBytes = Uint8List.fromList([...pcmBytes, 0]);
    }
    final int16View = Int16List.view(
      pcmBytes.buffer,
      pcmBytes.offsetInBytes,
      pcmBytes.lengthInBytes ~/ 2,
    );
    final float32List = Float32List(int16View.length);
    for (var i = 0; i < int16View.length; i++) {
      float32List[i] = int16View[i] / 32768.0;
    }
    return float32List;
  }

  /// Stop listening and return the final transcript for this hold.
  /// Returns '' when the hold produced no recognizable speech.
  Future<String> stop() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    _recorder = null;

    // Drain any speech segment still inside the VAD pipeline.
    return flushTail();
  }

  /// Whether the engine is currently listening.
  bool get isListening => _recorder != null;

  /// Whether the offline STT models are loaded and ready.
  bool get isReady => _initialized && _recognizer != null;

  /// Whether VAD (at minimum) is ready so PTT can capture audio.
  bool get vadReady => _vad != null;

  /// Current locale.
  String? get currentLocale => _currentLocale;

  /// Dispose resources.
  Future<void> dispose() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    _recorder = null;
    try {
      _recognizer?.free();
    } catch (_) {}
    _recognizer = null;
    try {
      _vad?.free();
    } catch (_) {}
    _vad = null;
    _initialized = false;
  }
}
