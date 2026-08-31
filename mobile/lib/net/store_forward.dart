import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../ml/ibfs.dart';
import 'transport.dart';

/// Store-and-forward queue — ADDITIONAL_FEATURES.md §3.
///
/// When the target peer is out of range, messages are queued locally
/// (with their Sequence ID for dedup) and auto-delivered on reconnect.
/// Uses Packet Type 0x4 (store-forward relay) from NETWORK_PROTOCOL.md.
class StoreForwardQueue {
  final Transport _transport;
  final List<_QueuedFrame> _queue = [];
  bool _processing = false;
  static const _prefsKey = 'itantra_queue';

  StoreForwardQueue(this._transport) {
    _loadFromDisk();
    _listenReconnect();
  }

  /// Queue a frame for later delivery. Returns the queue position.
  int enqueue(Uint8List frame, {int? sequenceId}) {
    final entry = _QueuedFrame(
      frame: frame,
      sequenceId: sequenceId ?? 0,
      queuedAt: DateTime.now(),
    );
    _queue.add(entry);
    _persistToDisk();
    _tryFlush();
    return _queue.length;
  }

  /// Number of queued messages.
  int get pendingCount => _queue.length;

  /// Whether any messages are queued.
  bool get hasPending => _queue.isNotEmpty;

  /// All queued entries (for UI display).
  List<_QueuedFrameInfo> get pending =>
      _queue.map((e) => _QueuedFrameInfo.fromFrame(e)).toList();

  /// Try to flush queued messages if transport is connected.
  void _tryFlush() {
    if (_processing || _queue.isEmpty) return;
    if (!_transport.isConnected) return;

    _processing = true;
    _flushNext();
  }

  Future<void> _flushNext() async {
    if (_queue.isEmpty) {
      _processing = false;
      _persistToDisk();
      return;
    }

    final entry = _queue.first;
    try {
      await _transport.send(entry.frame);
      _queue.removeAt(0);
      _persistToDisk();
      // Continue flushing.
      _flushNext();
    } catch (_) {
      // Transport failed — stop flushing, retry on next reconnect.
      _processing = false;
    }
  }

  /// Listen for transport reconnection to flush queue.
  void _listenReconnect() {
    // The transport's incoming stream becoming active indicates a peer
    // is connected. We periodically try to flush.
    Timer.periodic(const Duration(seconds: 5), (_) {
      _tryFlush();
    });
  }

  /// Clear all queued messages.
  void clear() {
    _queue.clear();
    _persistToDisk();
  }

  /// Remove a specific message by sequence ID.
  bool removeBySequenceId(int seqId) {
    final before = _queue.length;
    _queue.removeWhere((e) => e.sequenceId == seqId);
    final removed = before - _queue.length;
    _persistToDisk();
    return removed > 0;
  }

  // ── Persistence ────────────────────────────────────────────────

  Future<void> _persistToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final json = _queue.map((e) => e.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(json));
  }

  Future<void> _loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      for (final item in list) {
        final j = item as Map<String, dynamic>;
        final frameB64 = j['frame'] as String;
        final frame = base64Decode(frameB64);
        _queue.add(_QueuedFrame(
          frame: frame,
          sequenceId: j['seq'] as int,
          queuedAt: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        ));
      }
    } catch (_) {
      // Corrupted queue — start fresh.
    }
  }
}

class _QueuedFrame {
  final Uint8List frame;
  final int sequenceId;
  final DateTime queuedAt;

  _QueuedFrame({
    required this.frame,
    required this.sequenceId,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() => {
        'frame': base64Encode(frame),
        'seq': sequenceId,
        'ts': queuedAt.millisecondsSinceEpoch,
      };
}

class _QueuedFrameInfo {
  final int sequenceId;
  final DateTime queuedAt;
  final int frameSize;

  _QueuedFrameInfo({
    required this.sequenceId,
    required this.queuedAt,
    required this.frameSize,
  });

  factory _QueuedFrameInfo.fromFrame(_QueuedFrame f) => _QueuedFrameInfo(
        sequenceId: f.sequenceId,
        queuedAt: f.queuedAt,
        frameSize: f.frame.length,
      );
}
