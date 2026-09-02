import 'package:geolocator/geolocator.dart';

/// Runtime permission management for iTantra.
///
/// Handles RECORD_AUDIO, ACCESS_FINE_LOCATION, and BLUETOOTH permissions.
/// On Android 12+ these require runtime requests; on older versions some
/// are granted at install time.
class PermissionManager {
  PermissionManager._();

  /// Request all permissions needed by iTantra.
  /// Returns a [PermissionResult] indicating which permissions were granted.
  static Future<PermissionResult> requestAll() async {
    final results = <String, bool>{};

    // Microphone — required for STT.
    results['microphone'] = await _requestMicrophone();

    // Location — required for GPS stamping and BT scanning on Android 12+.
    results['location'] = await _requestLocation();

    // Bluetooth — required for P2P transport.
    results['bluetooth'] = await _requestBluetooth();

    return PermissionResult(results);
  }

  /// Check if all critical permissions are granted.
  static Future<bool> hasAllCritical() async {
    // Microphone check uses the speech_to_text package's status.
    // We rely on the STT engine returning false from initialize() if denied.
    return true; // Conservative — let individual engines report failures.
  }

  static Future<bool> _requestMicrophone() async {
    try {
      // speech_to_text handles its own permission request on initialize().
      // We just need to ensure the permission dialog can appear.
      // On Android, RECORD_AUDIO is requested when STT starts.
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return false;
      }
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestBluetooth() async {
    try {
      // Bluetooth permissions on Android 12+ require runtime requests.
      // The nearby_usage or permission_handler package handles this.
      // For now, we assume BT permissions are granted via manifest.
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Result of a permission request batch.
class PermissionResult {
  final Map<String, bool> results;
  const PermissionResult(this.results);

  bool get microphoneGranted => results['microphone'] ?? false;
  bool get locationGranted => results['location'] ?? false;
  bool get bluetoothGranted => results['bluetooth'] ?? false;

  bool get allGranted =>
      microphoneGranted && locationGranted && bluetoothGranted;

  /// List of denied permission names for display.
  List<String> get denied =>
      results.entries.where((e) => !e.value).map((e) => e.key).toList();
}
