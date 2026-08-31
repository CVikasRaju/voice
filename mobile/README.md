# iTantra — Android App (Flutter)

The runnable mobile application for SIH 26173. Implements the core loop from
`docs/ARCHITECTURE.md`: push-to-talk → on-device STT → iBFS-v1 binary frame →
link → decode + CRC → offline TTS → speaker, with distress escalation,
GPS stamping, language-mismatch handling (§2.4 Option A) and a non-dismissible
emergency alarm surface.

## 1. Prerequisites

- Flutter SDK **3.22.x stable** (`flutter --version`)
- Android Studio Hedgehog+ with SDK 34, JDK 17
- A physical Android device (speech recognition does not work reliably on emulators)

## 2. Generate platform folders & run

This repo ships the Dart source; the `android/` platform folder is generated
by the Flutter toolchain on first setup (gradle wrapper binaries are not
checked in):

```bash
cd mobile
flutter create . --project-name itantra --org in.sih.itantra --platforms android
flutter pub get
flutter run                # debug; use --profile when timing anything
```

Release APK (per `docs/SETUP_AND_BUILD.md` §6):

```bash
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

## 3. Required Android permissions

Merge into `android/app/src/main/AndroidManifest.xml` under `<manifest>`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
```

Also set `minSdkVersion 24` in `android/app/build.gradle`
(`defaultConfig { minSdk = 24 }`).

## 4. What works out of the box vs. production swap-ins

| Stage | This build | Production target |
|---|---|---|
| STT | Platform on-device recognizer (`onDevice: true`) via `speech_to_text` | sherpa-onnx + AI4Bharat INT8 models in `assets/models/stt/` — same interface in `lib/ml/stt_engine.dart` |
| TTS | Platform synthesizer via `flutter_tts` | sherpa-onnx VITS voices — same interface in `lib/ml/tts_engine.dart` |
| Link | `LoopbackTransport` (~35–90 ms jitter, radios off) | Bluetooth RFCOMM / Wi-Fi Direct implementing `Transport` in `lib/net/transport.dart`; inbound frames feed its `incoming` stream |
| Emergency audio | App-level max volume | Native module: `AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE` + `STREAM_ALARM` (ARCHITECTURE.md §2.3) — needs a small platform channel |

Model tooling lives at the repo root:

```bash
python scripts/fetch_models.py --lang hi,kn --quantize int8   # fill MODEL_SOURCES with pinned URLs
python scripts/quantize_models.py                             # FP32 -> INT8
python scripts/benchmark_latency.py --stt-dir assets/models/stt/hi --wav sample.wav
```

After fetching, uncomment the assets block in `mobile/pubspec.yaml`.

## 5. Validation checklist (SETUP_AND_BUILD.md §7–§8)

1. Sideload on two phones; toggle **Transceiver OFF** proves the app reverts
   to an ordinary phone (mic + link genuinely disabled).
2. Exercise every path with radios off: PTT utterance, typed traffic,
   distress keyword → SOS escalation + alarm overlay, GPS stamping (+9 B),
   sender/receiver language mismatch → text-only fallback.
3. Log real numbers from the packet log (stt / transfer / tts / e2e ms are
   measured per packet) — targets stay in README.md §5, claims come from here.
4. Then swap in a real `Transport` and repeat on two devices.
