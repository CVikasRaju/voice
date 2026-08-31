import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:shared_preferences/shared_preferences.dart';

import '../ml/ibfs.dart';
import '../ml/languages.dart';
import '../ml/stt_engine.dart';
import '../ml/tts_engine.dart';
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

  late final StoreForwardQueue storeForward;

  TransceiverController({
    required this.stt,
    required this.tts,
    required this.transport,
  }) {
    storeForward = StoreForwardQueue(transport);
    _listenInbound();
  }

  // ── State ──────────────────────────────────────────────────────
  TransceiverPhase _phase = TransceiverPhase.idle;
  TransceiverPhase get phase => _phase;

  bool _gpsEnabled = false;
  bool get gpsEnabled => _gpsEnabled;
  set gpsEnabled(bool v) {
    _gpsEnabled = v;
    notifyListeners();
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
  }

  String _interimText = '';
  String get interimText => _interimText;

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

  // ── PTT Controls ───────────────────────────────────────────────

  int? _sttStartMs;

  /// Begin recording on PTT press.
  Future<void> startPtt() async {
    if (_phase != TransceiverPhase.idle) return;

    _phase = TransceiverPhase.recording;
    _interimText = '';
    _sttStartMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();

    await stt.start(
      localeId: _senderLang.code,
      onResult: (text, isFinal) {
        _interimText = text;
        notifyListeners();
        if (isFinal) {
          _processTranscript(text);
        }
      },
    );
  }

  /// Stop recording on PTT release; process whatever we have.
  Future<void> stopPtt() async {
    if (_phase != TransceiverPhase.recording) return;

    _phase = TransceiverPhase.processing;
    notifyListeners();

    await stt.stop();
    // Give the engine a beat to flush the final result.
    await Future.delayed(const Duration(milliseconds: 350));

    if (_interimText.isNotEmpty) {
      await _processTranscript(_interimText);
    } else {
      _phase = TransceiverPhase.idle;
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
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.low,
            timeLimit: Duration(seconds: 5),
          ),
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

    // ── Transmit ──
    _phase = TransceiverPhase.transmitting;
    notifyListeners();

    final txStart = DateTime.now().millisecondsSinceEpoch;
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

    // ── Language mismatch: Option A (ARCHITECTURE.md §2.4) ──
    // If the sender's language doesn't match our receiver language,
    // display text only (don't attempt TTS in the wrong language).
    final ttsMs: int?;
    if (packet.language.iso639 == _receiverLang.iso639) {
      // Configure TTS for this language and speak.
      await tts.configure(packet.language.code, speechRate: 0.9);

      final ttsStart = DateTime.now().millisecondsSinceEpoch;
      await tts.speak(packet.text, emergency: packet.priority == Priority.emergency);
      ttsMs = DateTime.now().millisecondsSinceEpoch - ttsStart;
    } else {
      // Language mismatch — text only.
      ttsMs = null;
    }

    final e2eMs = DateTime.now().millisecondsSinceEpoch - e2eStart;

    _addLog(LogEntry(
      id: packet.sequenceId,
      timestamp: DateTime.now(),
      isSent: false,
      text: packet.text,
      langName: packet.language.name,
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
    super.dispose();
  }
}
