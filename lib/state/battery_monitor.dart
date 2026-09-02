import 'dart:async';

import 'package:flutter/foundation.dart';

/// Battery and thermal state monitor — ADDITIONAL_FEATURES.md §9.
///
/// Tracks battery level and thermal state to enable graceful degradation
/// when the device is resource-starved (common in disaster conditions).
class BatteryMonitor extends ChangeNotifier {
  int _level = 100;
  bool _isCharging = false;
  BatteryState _state = BatteryState.unknown;
  ThermalState _thermal = ThermalState.nominal;
  Timer? _pollTimer;

  int get level => _level;
  bool get isCharging => _isCharging;
  BatteryState get batteryState => _state;
  ThermalState get thermalState => _thermal;

  /// Whether the device is in a resource-constrained state.
  bool get isConstrained => _level < 20 || _thermal == ThermalState.critical;

  /// Whether we should reduce ML workload (throttle inference, skip GPS).
  bool get shouldThrottle => _level < 15 || _thermal == ThermalState.critical;

  /// Human-readable status summary.
  String get statusLabel {
    if (_thermal == ThermalState.critical) return 'Thermal critical';
    if (_thermal == ThermalState.severe) return 'Overheating';
    if (_level < 10) return 'Battery critical';
    if (_level < 20) return 'Low battery';
    return 'OK';
  }

  /// Start polling battery state every 30 seconds.
  void startMonitoring() {
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
  }

  /// Stop monitoring.
  void stopMonitoring() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _poll() async {
    try {
      // Battery state detection via platform channels would go here.
      // On Android: use BatteryManager API via method channel.
      // For now, we use a placeholder that the platform integration fills in.
      //
      // The real implementation would use:
      //   - MethodChannel('itantra/battery') to call Android BatteryManager
      //   - Query BATTERY_PROPERTY_CAPACITY for level
      //   - Query isCharging status
      //   - For thermal: read /sys/class/thermal/thermal_zone*/temp

      // Placeholder: assume nominal unless platform reports otherwise.
      _state = BatteryState.discharging;
      _thermal = ThermalState.nominal;
      notifyListeners();
    } catch (_) {
      // If we can't read battery, assume worst case for safety.
      _thermal = ThermalState.unknown;
      notifyListeners();
    }
  }

  /// Force-update from platform channel data.
  void updateFromPlatform({
    required int level,
    required bool isCharging,
    required BatteryState state,
    required ThermalState thermal,
  }) {
    _level = level;
    _isCharging = isCharging;
    _state = state;
    _thermal = thermal;
    notifyListeners();
  }

  @override
  void dispose() {
    stopMonitoring();
    super.dispose();
  }
}

enum BatteryState {
  charging,
  discharging,
  full,
  unknown,
}

enum ThermalState {
  nominal,
  light,
  moderate,
  severe,
  critical,
  unknown,
}
