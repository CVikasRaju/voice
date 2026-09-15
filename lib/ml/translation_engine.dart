import 'package:flutter/foundation.dart';

import 'languages.dart';

/// Cross-lingual translation bridge (NETWORK_PROTOCOL.md §6).
///
/// When sender and receiver speak different languages, the receiver
/// displays the original transcribed text (text-only fallback).
/// ML Kit on-device translation was removed to reduce APK size by ~50 MB.
/// Translation can be re-added later if a lighter engine is found.
class TranslationEngine {
  /// Whether ML Kit supports the given app language.
  /// Always false — translation is currently disabled for size reduction.
  static bool isSupported(Lang lang) => false;

  /// Ensure the translation models for [source]→[target] are on device.
  /// Returns `false` (translation unavailable).
  Future<bool> ensureModels(Lang source, Lang target) async => false;

  /// Translate [text] from [source] to [target] fully offline.
  /// Returns `null` — cross-language translation is disabled.
  /// The receiver sees the original text in the packet log.
  Future<String?> translate(String text, Lang source, Lang target) async {
    if (text.trim().isEmpty) return null;
    if (source.iso639 == target.iso639) return text;
    // Translation unavailable — caller falls back to original text.
    debugPrint('[TranslationEngine] Translation unavailable '
        '(${source.iso639} → ${target.iso639}); showing original text');
    return null;
  }

  /// Free translator resources (no-op).
  Future<void> dispose() async {}
}
