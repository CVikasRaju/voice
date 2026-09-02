import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// P2P link abstraction (ARCHITECTURE.md §2 transport stage).
///
/// A real deployment implements this over Bluetooth RFCOMM / Wi-Fi Direct:
/// `send()` writes the raw iBFS frame to the socket, and unsolicited inbound
/// frames arrive on `incoming`. Nothing above this layer knows or cares which
/// radio carries the bytes.
abstract class Transport {
  /// Writes one frame onto the link; resolves after the radio accepts it.
  Future<int> send(Uint8List frame);

  /// Inbound frames from a connected peer.
  Stream<Uint8List> get incoming;

  /// Whether a peer is connected.
  bool get isConnected;

  /// Tear down the connection.
  Future<void> disconnect();
}

/// Loopback transport for development and demo (no radios needed).
///
/// Simulates a round-trip delay of [minMs]–[maxMs] milliseconds (default
/// 35–90 ms, matching RFCOMM benchmarks). No encryption, no real radio.
class LoopbackTransport implements Transport {
  final int minMs;
  final int maxMs;
  final _controller = StreamController<Uint8List>.broadcast();
  bool _connected = true;
  final _rng = Random();

  LoopbackTransport({this.minMs = 35, this.maxMs = 90});

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<int> send(Uint8List frame) async {
    if (!_connected) throw StateError('Transport not connected');

    final delay = minMs + _rng.nextInt(maxMs - minMs + 1);
    await Future.delayed(Duration(milliseconds: delay));

    // Loopback: echo the frame back on the incoming stream.
    if (!_controller.isClosed) {
      _controller.add(frame);
    }

    return delay;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _controller.close();
  }
}
