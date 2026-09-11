import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

/// BLE GATT mesh transport (NETWORK_PROTOCOL.md §2 transport stage).
///
/// Every device runs BOTH roles simultaneously:
///  - Peripheral: advertises the iTantra service and accepts writes.
///  - Central: scans for other iTantra peripherals, connects, subscribes.
///
/// A frame written by a central to any subscribed peer is relayed to all
/// other connected peers with a decremented TTL, forming a flooding mesh.
class BleMeshTransport {
  BleMeshTransport._();

  static final BleMeshTransport instance = BleMeshTransport._();

  // ── iTantra GATT identifiers (custom 128-bit UUIDs) ──────────────
  static final UUID serviceUuid =
      UUID.fromString('8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a10');
  static final UUID frameCharUuid =
      UUID.fromString('8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a11');

  /// Max hops a frame may traverse (iBFS TTL policy).
  static const int maxHops = 8;

  final PeripheralManager _peripheral = PeripheralManager();
  final CentralManager _central = CentralManager();

  final _controller = StreamController<Uint8List>.broadcast();
  final Map<UUID, Peripheral> _connected = {};
  final Map<UUID, GATTCharacteristic> _peerFrameChars = {};
  final Set<Central> _subscribedCentrals = {};
  final List<String> _seenFrames = [];
  int _hopCount = maxHops;

  GATTCharacteristic? _frameChar;
  bool _running = false;
  StreamSubscription? _sub1;
  StreamSubscription? _sub2;
  StreamSubscription? _sub3;
  StreamSubscription? _sub4;

  /// Inbound (and relayed) iBFS frames from the mesh.
  Stream<Uint8List> get incoming => _controller.stream;

  /// Whether the mesh layer is running.
  bool get isRunning => _running;

  /// Number of currently connected mesh peers.
  int get peerCount => _connected.length;

  /// Start advertising + scanning. Requests BLE permissions first.
  Future<bool> start() async {
    if (_running) return true;
    try {
      // ── Permissions & power state ──
      final authorized = await _central.authorize();
      if (!authorized) return false;
      if (_central.state != BluetoothLowEnergyState.poweredOn) {
        return false;
      }

      // ── Peripheral role: publish service & advertise ──
      _frameChar = GATTCharacteristic.mutable(
        uuid: frameCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );
      final service = GATTService(
        uuid: serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [_frameChar!],
      );
      await _peripheral.addService(service);

      await _peripheral.startAdvertising(Advertisement(
        name: 'iTantra',
        manufacturerSpecificData: [],
      ));

      // ── Event wiring ──
      _sub1 = _central.discovered.listen(_onDiscovered);
      _sub2 = _central.connectionStateChanged.listen(_onCentralConnChanged);
      _sub3 = _central.characteristicNotified.listen(_onNotified);
      _sub4 = _peripheral.characteristicWriteRequested
          .listen(_onWriteRequested);
      _peripheral.characteristicNotifyStateChanged
          .listen(_onNotifyStateChanged);

      // ── Central role: scan for other iTantra peripherals ──
      await _central.startDiscovery(serviceUUIDs: [serviceUuid]);

      _running = true;
      return true;
    } catch (e) {
      debugPrint('BleMeshTransport.start failed: $e');
      await stop();
      return false;
    }
  }

  /// Send an iBFS frame: write to every connected peer (they relay with
  /// TTL) and notify directly-subscribed centrals.
  Future<int> send(Uint8List frame) async {
    if (!_running) throw StateError('BLE mesh not started');
    var fanout = 0;

    // Write to other peripherals we are connected to as central.
    for (final entry in _connected.entries) {
      final char = _peerFrameChars[entry.key];
      if (char == null) continue;
      try {
        await _central.writeCharacteristic(
          entry.value,
          char,
          value: frame,
          type: GATTCharacteristicWriteType.withoutResponse,
        );
        fanout++;
      } catch (e) {
        debugPrint('BLE write to ${entry.key} failed: $e');
      }
    }

    // Notify subscribed centrals (peripheral role).
    final char = _frameChar;
    if (char != null) {
      for (final central in List.of(_subscribedCentrals)) {
        try {
          await _peripheral.notifyCharacteristic(
            central,
            char,
            value: frame,
          );
          fanout++;
        } catch (e) {
          debugPrint('BLE notify failed: $e');
        }
      }
    }

    return fanout;
  }

  void _onDiscovered(DiscoveredEventArgs args) {
    final key = args.peripheral.uuid;
    if (_connected.containsKey(key)) return;
    if (args.advertisement.serviceUUIDs.contains(serviceUuid)) {
      // Fire-and-forget connect; results arrive via connectionStateChanged.
      _central.connect(args.peripheral).then((_) {}, onError: (e) {
        debugPrint('BLE connect to $key failed: $e');
      });
    }
  }

  void _onCentralConnChanged(PeripheralConnectionStateChangedEventArgs args) {
    final key = args.peripheral.uuid;
    if (args.state == ConnectionState.connected) {
      _connected[key] = args.peripheral;
      _subscribeAndRequestMtu(args.peripheral);
    } else {
      _connected.remove(key);
      _peerFrameChars.remove(key);
    }
  }

  Future<void> _subscribeAndRequestMtu(Peripheral peripheral) async {
    try {
      await _central.requestMTU(peripheral, mtu: 517);
      final services = await _central.discoverGATT(peripheral);
      for (final service in services) {
        if (service.uuid != serviceUuid) continue;
        for (final char in service.characteristics) {
          if (char.uuid == frameCharUuid) {
            _peerFrameChars[peripheral.uuid] = char;
            await _central.setCharacteristicNotifyState(
              peripheral,
              char,
              state: true,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('BLE subscribe failed: $e');
    }
  }

  void _onNotified(GATTCharacteristicNotifiedEventArgs args) {
    if (args.characteristic.uuid != frameCharUuid) return;
    _dispatch(args.value);
  }

  void _onNotifyStateChanged(GATTCharacteristicNotifyStateChangedEventArgs args) {
    if (args.characteristic.uuid != frameCharUuid) return;
    if (args.state) {
      _subscribedCentrals.add(args.central);
    } else {
      _subscribedCentrals.remove(args.central);
    }
  }

  Future<void> _onWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs args,
  ) async {
    try {
      await _peripheral.respondWriteRequest(args.request);
      _dispatch(args.request.value);
    } catch (e) {
      debugPrint('BLE write response failed: $e');
    }
  }

  /// Dedup + relay logic. Frames are identified by their sequence ID
  /// (bytes 4–7 of the iBFS header) and relayed until the hop budget
  /// is exhausted.
  void _dispatch(Uint8List frame) {
    if (frame.length < 8) return;
    final key =
        '${frame[4]}-${frame[5]}-${frame[6]}-${frame[7]}';
    if (_seenFrames.contains(key)) return; // Already seen — don't relay again.
    _seenFrames.add(key);
    if (_seenFrames.length > 512) _seenFrames.removeAt(0);

    _controller.add(frame);

    // Relay to other peers while hop budget allows.
    if (_hopCount > 0) {
      _hopCount--;
      send(frame).then((_) {}, onError: (e) {
        debugPrint('BLE relay failed: $e');
      });
    }
  }

  /// Reset the hop budget when the local device originates a new frame.
  void resetHops() {
    _hopCount = maxHops;
  }

  /// Stop the mesh and release radios.
  Future<void> stop() async {
    _running = false;
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    for (final p in List.of(_connected.values)) {
      try {
        await _central.disconnect(p);
      } catch (_) {}
    }
    _connected.clear();
    _peerFrameChars.clear();
    _subscribedCentrals.clear();
    try {
      await _peripheral.stopAdvertising();
    } catch (_) {}
    await _sub1?.cancel();
    await _sub2?.cancel();
    await _sub3?.cancel();
    await _sub4?.cancel();
    _sub1 = _sub2 = _sub3 = _sub4 = null;
  }

  /// Tear down completely.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
