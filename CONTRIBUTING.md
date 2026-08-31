# Contributing to iTantra

Thank you for your interest in contributing to iTantra — the Indian Multilingual Neural Transceiver for disaster communication.

## How to Contribute

### 1. Fork & Clone

```bash
git clone https://github.com/<your-username>/iTantra.git
cd iTantra
```

### 2. Set Up Development Environment

```bash
# Install Flutter SDK 3.22.x
# Install Android Studio Hedgehog+
# Install Python 3.10+ for scripts

cd mobile
flutter create . --project-name itantra --org in.sih.itantra --platforms android
flutter pub get
```

### 3. Build Order

Follow the build order in `docs/SETUP_AND_BUILD.md` §5:

1. Offline STT+TTS working for **one** language, one phone, no networking.
2. Two-phone loop over Bluetooth RFCOMM, same one language.
3. Push-to-talk UI + emergency alert override.
4. Scale to remaining 9 languages.
5. Add differentiators from `docs/ADDITIONAL_FEATURES.md` only after step 4 is stable.

**Do not build UI polish or extra features before the core offline loop works end-to-end on real hardware.**

### 4. Code Style

- **Flutter/Dart**: Follow `analysis_options.yaml` strict lint rules.
- **Python**: PEP 8 with type hints.
- **Documentation**: Markdown with clear section headers.
- **Commit messages**: Conventional commits (`feat:`, `fix:`, `docs:`, `test:`).

### 5. Testing

Before submitting a PR:

```bash
# Run Dart analyzer
cd mobile
dart analyze

# Run unit tests
flutter test

# Run Python script checks
python3 -m py_compile scripts/fetch_models.py
python3 -m py_compile scripts/quantize_models.py
python3 -m py_compile scripts/benchmark_latency.py
```

### 6. Model Contributions

If you're contributing model conversions or quantization:

1. Document the source model and conversion process in `docs/ML_PIPELINE.md`.
2. Add license attribution in `docs/MODEL_LICENSES.md`.
3. Verify WER delta pre/post quantization on a held-out test set.
4. Test on real Android hardware, not just your dev machine.

### 7. Protocol Changes

Changes to `docs/NETWORK_PROTOCOL.md` (iBFS-v1 wire format) must:

1. Maintain backward compatibility with existing packets.
2. Update the encoder/decoder in `mobile/lib/ml/ibfs.dart`.
3. Update the test suite in `mobile/test/ibfs_test.dart`.
4. Document the change in the protocol spec.

### 8. Pull Request Process

1. Create a feature branch from `main`.
2. Make your changes following the guidelines above.
3. Ensure all tests pass.
4. Update documentation if needed.
5. Submit a PR with a clear description of what changed and why.

### 9. Code of Conduct

Be respectful, inclusive, and constructive. This project serves disaster response — every contribution matters.

## Questions?

Open a GitHub Discussion or tag `@maintainer` in your issue.
