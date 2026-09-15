import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:shared_preferences/shared_preferences.dart';

import '../ml/ibfs.dart';
import '../ml/languages.dart';
import '../ml/stt_engine.dart';
import '../ml/translation_engine.dart';
import '../ml/tts_engine.dart';
import '../ml/tts_model_downloader.dart';
import '../net/store_forward.dart';
import '../net/transport.dart';

/// ── Phase Enum (ARCHITECTURE.md §3) ─────────────────────────────

enum TransceiverPhase {
  idle, // listening for inbound only
  recording, // PTT held, mic capturing
  processing, // STT running on buffered audio
  transmitting, // frame on the wire
}

/// ── Log Entry ───────────────────────────────────────────────────

class LogEntry {
  final int id;
  final DateTime timestamp;
  final bool isSent; // true = transmitted, false = received
  final String text;
  final String langName;
  final Priority priority;
  final int? sttMs;
  final int? transferMs;
  final int? ttsMs;
  final int? e2eMs;
  final double? lat;
  final double? lon;
  final String? error;

  const LogEntry({
    required this.id,
    required this.timestamp,
    required this.isSent,
    required this.text,
    required this.langName,
    required this.priority,
    this.sttMs,
    this.transferMs,
    this.ttsMs,
    this.e2eMs,
    this.lat,
    this.lon,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': timestamp.millisecondsSinceEpoch,
        'sent': isSent,
        'text': text,
        'lang': langName,
        'priority': priority.value,
        'sttMs': sttMs,
        'txMs': transferMs,
        'ttsMs': ttsMs,
        'e2eMs': e2eMs,
        'lat': lat,
        'lon': lon,
        'error': error,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: j['id'] as int,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        isSent: j['sent'] as bool,
        text: j['text'] as String,
        langName: j['lang'] as String,
        priority: Priority.values.firstWhere(
          (p) => p.value == j['priority'],
          orElse: () => Priority.routine,
        ),
        sttMs: j['sttMs'] as int?,
        transferMs: j['txMs'] as int?,
        ttsMs: j['ttsMs'] as int?,
        e2eMs: j['e2eMs'] as int?,
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        error: j['error'] as String?,
      );
}

/// ── Transceiver Controller ──────────────────────────────────────

/// Core PTT state machine (ARCHITECTURE.md §3).
///
/// All mutation flows through this class. Widgets are projections of
/// its [ValueNotifier] fields.
class TransceiverController extends ChangeNotifier {
  final SttEngine stt;
  final TtsEngine tts;
  final Transport transport;
  final TranslationEngine translator;

  late final StoreForwardQueue storeForward;

  TransceiverController({
    required this.stt,
    required this.tts,
    required this.transport,
    TranslationEngine? translator,
  }) : translator = translator ?? TranslationEngine() {
    storeForward = StoreForwardQueue(transport);
    _listenInbound();
    _loadPrefs();
    // Delay BLE mesh start to allow permissions to be granted first.
    // The HomeScreen._requestPermissions() runs in initState and triggers
    // enableMesh() once BT permissions are granted. This timer is a fallback
    // in case the user grants permissions before the UI is ready.
    Future.delayed(const Duration(seconds: 3), () {
      if (!_meshActive) _startMeshOnInit();
    });
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _gpsEnabled = prefs.getBool('gpsEnabled') ?? true;
    notifyListeners();
  }

  /// Auto-start BLE mesh in the background.
  Future<void> _startMeshOnInit() async {
    final t = transport;
    if (t is! SwitchableTransport) return;
    final ok = await t.enableMesh();
    _meshActive = ok;
    notifyListeners();
  }

  // ── State ──────────────────────────────────────────────────────
  TransceiverPhase _phase = TransceiverPhase.idle;
  TransceiverPhase get phase => _phase;

  bool _gpsEnabled = true; // Default on — users expect GPS to work out of the box.
  bool get gpsEnabled => _gpsEnabled;
  set gpsEnabled(bool v) {
    _gpsEnabled = v;
    notifyListeners();
    // Persist preference.
    SharedPreferences.getInstance().then((p) => p.setBool('gpsEnabled', v));
  }

  Lang _senderLang = kHindi;
  Lang get senderLang => _senderLang;
  set senderLang(Lang v) {
    _senderLang = v;
    notifyListeners();
  }

  Lang _receiverLang = kHindi;
  Lang get receiverLang => _receiverLang;
  set receiverLang(Lang v) {
    _receiverLang = v;
    notifyListeners();
    // Prepare the neural voice for the new receiver language.
    _ensureTtsModels(v);
  }

  String _interimText = '';
  String get interimText => _interimText;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;
  void clearStatusMessage() {
    _statusMessage = null;
    notifyListeners();
  }

  int _sequenceId = 0;

  /// Typed text to send (fallback when STT is unavailable).
  String _typedText = '';
  String get typedText => _typedText;
  set typedText(String v) {
    _typedText = v;
    notifyListeners();
  }

  bool _alarmActive = false;
  bool get alarmActive => _alarmActive;

  Priority _alarmPriority = Priority.emergency;
  Priority get alarmPriority => _alarmPriority;

  final List<LogEntry> _log = [];
  List<LogEntry> get log => List.unmodifiable(_log);

  // ── Model Download State ───────────────────────────────────────

  bool _modelsDownloading = false;
  bool get modelsDownloading => _modelsDownloading;

  double _modelsDownloadProgress = 0.0;
  double get modelsDownloadProgress => _modelsDownloadProgress;

  String _modelsDownloadStatus = '';
  String get modelsDownloadStatus => _modelsDownloadStatus;

  /// Whether the sender language models are ready for offline STT.
  bool get senderModelsReady => stt.isReady && stt.currentLocale == _senderLang.code;

  // ── TTS Model Download State ──────────────────────────────────

  bool _ttsDownloading = false;
  bool get ttsDownloading => _ttsDownloading;

  double _ttsDownloadProgress = 0.0;
  double get ttsDownloadProgress => _ttsDownloadProgress;

  String _ttsDownloadStatus = '';
  String get ttsDownloadStatus => _ttsDownloadStatus;

  /// Whether the receiver language has a neural TTS engine ready.
  bool get receiverTtsReady => tts.isNeuralReadyFor(_receiverLang);

  /// Download + initialize the neural TTS model for the receiver language.
  Future<bool> downloadReceiverTtsModels() async {
    return _ensureTtsModels(_receiverLang);
  }

  Future<bool> _ensureTtsModels(Lang lang) async {
    // Already loaded for THIS language?
    if (tts.isNeuralReadyFor(lang)) return true;
    // No neural model exists for this language (e.g. Odia) — platform TTS.
    if (!TtsModelDownloader.hasNeuralModel(lang)) return false;
    if (_ttsDownloading) return false;

    _ttsDownloading = true;
    _ttsDownloadProgress = 0.0;
    _ttsDownloadStatus = 'Preparing ${lang.name} voice…';
    notifyListeners();

    // Download if not present.
    var available = await TtsModelDownloader.areModelsAvailable(lang);
    if (!available) {
      available = await TtsModelDownloader.downloadModels(
        lang,
        onProgress: (p) {
          _ttsDownloadProgress = p;
          _ttsDownloadStatus =
              'Downloading ${lang.name} voice… ${(p * 100).toInt()}%';
          notifyListeners();
        },
      );
    }

    _ttsDownloading = false;
    if (available) {
      final loaded = await tts.initNeural(lang);
      _ttsDownloadStatus = loaded
          ? '${lang.name} neural voice ready'
          : '${lang.name} voice unavailable — using platform TTS';
    } else {
      _ttsDownloadStatus = 'Voice download failed — check connection';
    }
    notifyListeners();
    return available;
  }

  /// Download models for the current sender language.
  Future<void> downloadSenderModels() async {
    if (_modelsDownloading) return;

    _modelsDownloading = true;
    _modelsDownloadProgress = 0.0;
    _modelsDownloadStatus = 'Preparing ${_senderLang.name} models…';
    notifyListeners();

    final success = await stt.prepareModels(
      _senderLang,
      onProgress: (progress) {
        _modelsDownloadProgress = progress;
        _modelsDownloadStatus =
            'Downloading ${_senderLang.name} models… ${(progress * 100).toInt()}%';
        notifyListeners();
      },
    );

    _modelsDownloading = false;
    if (success) {
      // Auto-initialize the recognizer with the new models.
      final initErr = await stt.init(_senderLang);
      if (initErr == null) {
        _modelsDownloadStatus = '${_senderLang.name} models ready ✓';
      } else {
        // Show the real sherpa-onnx error to the user.
        _modelsDownloadStatus = 'Load failed: $initErr';
      }
    } else {
      _modelsDownloadStatus = 'Download failed — check connection';
    }
    notifyListeners();
  }

  /// Pre-download models for a language in the background.
  Future<void> predownloadModels(Lang lang) async {
    if (_modelsDownloading) return;

    _modelsDownloading = true;
    _modelsDownloadProgress = 0.0;
    _modelsDownloadStatus = 'Preparing ${lang.name} models…';
    notifyListeners();

    final success = await stt.prepareModels(
      lang,
      onProgress: (progress) {
        _modelsDownloadProgress = progress;
        _modelsDownloadStatus =
            'Downloading ${lang.name} models… ${(progress * 100).toInt()}%';
        notifyListeners();
      },
    );

    _modelsDownloading = false;
    if (success) {
      final initErr = await stt.init(lang);
      if (initErr == null) {
        _modelsDownloadStatus = '${lang.name} models ready ✓';
      } else {
        _modelsDownloadStatus = 'Load failed: $initErr';
      }
    } else {
      _modelsDownloadStatus = 'Download failed — check connection';
    }
    notifyListeners();
  }

  // ── Mesh Transport ────────────────────────────────────────────

  bool _meshActive = false;
  bool get meshActive => _meshActive;

  /// Enable the BLE mesh transport (falls back to loopback on failure).
  Future<bool> enableMesh() async {
    final t = transport;
    if (t is! SwitchableTransport) return false;
    if (_meshActive) return true;
    final ok = await t.enableMesh();
    _meshActive = ok;
    notifyListeners();
    return ok;
  }

  /// Number of connected mesh peers (0 in loopback mode).
  int get meshPeerCount =>
      transport is SwitchableTransport
          ? (transport as SwitchableTransport).meshPeerCount
          : 0;

  // ── PTT Controls ───────────────────────────────────────────────

  int? _sttStartMs;

  bool get isRecording => _phase == TransceiverPhase.recording;
  bool get isProcessing => _phase == TransceiverPhase.processing;

  /// Begin recording on PTT press or tap.
  Future<void> startPtt() async {
    if (_phase != TransceiverPhase.idle) return;

    _statusMessage = null;
    _phase = TransceiverPhase.recording;
    _interimText = '';
    _sttStartMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();

    // If the offline STT model isn't loaded yet, kick off a download in
    // the background. The hold still captures audio (VAD + fallbacks),
    // so the user is never blocked — but without this, first-time users
    // only ever see "No speech detected" until they find the download
    // button manually.
    if (!stt.isReady || stt.currentLocale != _senderLang.code) {
      downloadSenderModels();
      _statusMessage =
          'Preparing ${_senderLang.name} speech model — voice captured, '
          'transcription improves when the model finishes downloading';
      notifyListeners();
    }

    await stt.start(
      localeId: _senderLang.code,
      onResult: (text, isFinal) {
        _interimText = text;
        notifyListeners();
        if (isFinal && text.trim().isNotEmpty) {
          _processTranscript(text);
        }
      },
    );

    // If stt.start() finished without starting the recorder (e.g. error),
    // reset phase to idle so UI recovers.
    if (!stt.isListening && _phase == TransceiverPhase.recording) {
      _phase = TransceiverPhase.idle;
      _statusMessage = 'Microphone not available — check permissions';
      notifyListeners();
    }
  }

  /// Stop recording on PTT release or second tap; process speech.
  Future<void> stopPtt() async {
    if (_phase != TransceiverPhase.recording) return;

    _phase = TransceiverPhase.processing;
    notifyListeners();

    // If recorder was still activating (mic stream setup taking 100-300ms),
    // wait up to 1.5s for recorder to activate so speech is not lost!
    for (var i = 0; i < 15 && !stt.isListening; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    if (!stt.isListening) {
      _phase = TransceiverPhase.idle;
      _interimText = '';
      _statusMessage = 'Microphone was not active — tap and speak';
      notifyListeners();
      return;
    }

    // stop() flushes any speech segment still inside the VAD pipeline,
    // so a short utterance spoken right before release is not lost.
    final flushed = await stt.stop();
    final text = (flushed.trim().isNotEmpty ? flushed : _interimText).trim();

    if (text.isNotEmpty) {
      await _processTranscript(text);
    } else {
      _phase = TransceiverPhase.idle;
      _interimText = '';
      // Distinguish "mic never started" from "mic ran but heard nothing".
      // Blanket "speak clearly" advice is wrong when the real cause is a
      // model still downloading or a voice too quiet for the STT model.
      _statusMessage = stt.isReady
          ? 'No transcription — speak louder and closer to the mic'
          : 'Speech model still downloading — tap PTT again in a moment '
              'or type your message below';
      notifyListeners();
    }
  }

  /// Process the final transcript and transmit.
  Future<void> _processTranscript(String text) async {
    if (text.trim().isEmpty) {
      _phase = TransceiverPhase.idle;
      _interimText = '';
      notifyListeners();
      return;
    }

    // Ensure phase is processing (Encode stage active)
    _phase = TransceiverPhase.processing;
    notifyListeners();

    final e2eStart = DateTime.now().millisecondsSinceEpoch;
    final sttMs = _sttStartMs != null
        ? e2eStart - _sttStartMs!
        : 0;
    _sttStartMs = null;

    // ── Distress detection (ADDITIONAL_FEATURES.md §1) ──
    final isDistress = detectDistress(text, _senderLang.iso639);
    final priority = isDistress ? Priority.emergency : Priority.routine;

    // ── GPS stamping (ADDITIONAL_FEATURES.md §2) ──
    double? lat;
    double? lon;
    if (_gpsEnabled) {
      try {
        final pos = await geo.Geolocator.getCurrentPosition(
          desiredAccuracy: geo.LocationAccuracy.low,
          timeLimit: const Duration(seconds: 5),
        );
        lat = pos.latitude;
        lon = pos.longitude;
      } catch (_) {
        // GPS unavailable — continue without it.
      }
    }

    // ── Encode ──
    _sequenceId++;
    final flags = PayloadFlags(
      hasGps: lat != null && lon != null,
    );

    final packet = IbfPacket(
      type: PacketType.pttVoice,
      priority: priority,
      language: _senderLang,
      sequenceId: _sequenceId,
      text: text,
      flags: flags,
      latitude: lat,
      longitude: lon,
    );

    final frame = encodeIbfs(packet);

    // Brief visual pause so the user sees the Encode stage light up
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // ── Transmit ──
    _phase = TransceiverPhase.transmitting;
    notifyListeners();

    int transferMs;
    try {
      transferMs = await transport.send(frame);
    } catch (e) {
      // Queue for store-and-forward (ADDITIONAL_FEATURES.md §3).
      storeForward.enqueue(frame, sequenceId: _sequenceId);
      _addLog(LogEntry(
        id: _sequenceId,
        timestamp: DateTime.now(),
        isSent: true,
        text: text,
        langName: _senderLang.name,
        priority: priority,
        sttMs: sttMs,
        lat: lat,
        lon: lon,
        error: 'Queued (${storeForward.pendingCount} pending)',
      ));
      _phase = TransceiverPhase.idle;
      _interimText = '';
      notifyListeners();
      return;
    }

    final e2eMs = DateTime.now().millisecondsSinceEpoch - e2eStart;

    _addLog(LogEntry(
      id: _sequenceId,
      timestamp: DateTime.now(),
      isSent: true,
      text: text,
      langName: _senderLang.name,
      priority: priority,
      sttMs: sttMs,
      transferMs: transferMs,
      e2eMs: e2eMs,
      lat: lat,
      lon: lon,
    ));

    _phase = TransceiverPhase.idle;
    _interimText = '';
    notifyListeners();
  }

  // ── Receive Path ───────────────────────────────────────────────

  void _listenInbound() {
    transport.incoming.listen((bytes) {
      _handleInbound(bytes);
    });
  }

  Future<void> _handleInbound(Uint8List bytes) async {
    final e2eStart = DateTime.now().millisecondsSinceEpoch;

    // ── Decode ──
    IbfPacket packet;
    try {
      packet = decodeIbfs(bytes);
    } catch (e) {
      _addLog(LogEntry(
        id: -1,
        timestamp: DateTime.now(),
        isSent: false,
        text: '[Corrupt frame dropped]',
        langName: '—',
        priority: Priority.routine,
        error: e.toString(),
      ));
      return;
    }

    // ── Cross-lingual translation + neural TTS (ARCHITECTURE.md §2.4) ──
    // If the packet language differs from our receiver language, translate
    // the text on-device (ML Kit), then speak the translation with the
    // receiver language's neural voice.
    final bool sameLang = packet.language.iso639 == _receiverLang.iso639;
    String displayText = packet.text;
    String spokenText = packet.text;
    Lang ttsLang = packet.language;

    if (!sameLang) {
      // Ensure the receiver's voice is available (downloads once, ~114 MB).
      await _ensureTtsModels(_receiverLang);

      final translated = await translator.translate(
        packet.text,
        packet.language,
        _receiverLang,
      );
      if (translated != null) {
        displayText = '${packet.text} → $translated';
        spokenText = translated;
        ttsLang = _receiverLang;
      }
      // Translation unavailable: fall back to showing the original text.
    } else {
      // Same language: still make sure the neural voice is ready.
      await _ensureTtsModels(_receiverLang);
    }

    final int? ttsMs;
    // Speak in the (possibly translated) target language.
    final ttsStart = DateTime.now().millisecondsSinceEpoch;
    await tts.speak(spokenText,
        lang: ttsLang, emergency: packet.priority == Priority.emergency);
    ttsMs = DateTime.now().millisecondsSinceEpoch - ttsStart;

    final e2eMs = DateTime.now().millisecondsSinceEpoch - e2eStart;

    _addLog(LogEntry(
      id: packet.sequenceId,
      timestamp: DateTime.now(),
      isSent: false,
      text: displayText,
      langName: sameLang ? packet.language.name : '${packet.language.name} → ${_receiverLang.name}',
      priority: packet.priority,
      ttsMs: ttsMs,
      e2eMs: e2eMs,
      lat: packet.latitude,
      lon: packet.longitude,
    ));

    // ── Emergency alarm override (ARCHITECTURE.md §2.3) ──
    if (packet.priority == Priority.emergency) {
      _alarmActive = true;
      _alarmPriority = Priority.emergency;
      notifyListeners();

      // Auto-dismiss after 9 seconds.
      await Future.delayed(const Duration(seconds: 9));
      _alarmActive = false;
      notifyListeners();
    }
  }

  /// Manually dismiss the alarm.
  void dismissAlarm() {
    _alarmActive = false;
    notifyListeners();
  }

  // ── Log persistence ────────────────────────────────────────────

  void _addLog(LogEntry entry) {
    _log.add(entry);
    notifyListeners();
    _persistLog();
  }

  Future<void> _persistLog() async {
    final prefs = await SharedPreferences.getInstance();
    final json = _log.map((e) => e.toJson()).toList();
    await prefs.setString('itantra_log', jsonEncode(json));
  }

  /// Load persisted log from disk.
  Future<void> loadLog() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('itantra_log');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _log.clear();
      _log.addAll(list.map((j) => LogEntry.fromJson(j as Map<String, dynamic>)));
      notifyListeners();
    } catch (_) {
      // Corrupted log — start fresh.
    }
  }

  /// Send typed text directly (bypasses STT).
  Future<void> sendTypedText(String text) async {
    if (text.trim().isEmpty) return;
    if (_phase != TransceiverPhase.idle) return;

    _typedText = '';
    notifyListeners();
    await _processTranscript(text.trim());
  }

  /// Number of queued messages waiting for peer reconnection.
  int get queuedCount => storeForward.pendingCount;
  bool get hasQueuedMessages => storeForward.hasPending;

  /// Clear the packet log.
  Future<void> clearLog() async {
    _log.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('itantra_log');
  }

  @override
  void dispose() {
    transport.disconnect();
    stt.dispose();
    tts.dispose();
    translator.dispose();
    super.dispose();
  }
}
