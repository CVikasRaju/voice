import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'languages.dart';

/// Offline cross-lingual translation bridge (NETWORK_PROTOCOL.md §6).
///
/// Uses ML Kit's on-device translator: models are ~30 MB each and are
/// downloaded once (requires internet), after which translation runs
/// fully offline. Translation only engages when the sender's language
/// differs from the receiver's language.
class TranslationEngine {
  final Map<String, OnDeviceTranslator> _translators = {};
  final Set<String> _ensuredModels = {};

  /// Map app ISO 639 codes to ML Kit [TranslateLanguage] values.
  /// Supported Indic languages: Hindi, Bengali, Gujarati, Kannada,
  /// Marathi, Tamil, Telugu + English.
  /// NOTE: ML Kit's on-device translator does not offer Malayalam or
  /// Odia — those languages fall back to text-only display.
  static const Map<String, TranslateLanguage> _mlKitLanguages = {
    'hi': TranslateLanguage.hindi,
    'bn': TranslateLanguage.bengali,
    'gu': TranslateLanguage.gujarati,
    'kn': TranslateLanguage.kannada,
    'mr': TranslateLanguage.marathi,
    'ta': TranslateLanguage.tamil,
    'te': TranslateLanguage.telugu,
    'en': TranslateLanguage.english,
  };

  /// Whether ML Kit supports the given app language.
  static bool isSupported(Lang lang) =>
      _mlKitLanguages.containsKey(lang.iso639);

  TranslateLanguage? _mlKitLang(Lang lang) => _mlKitLanguages[lang.iso639];

  /// Ensure the ML Kit translation models for [source]→[target] are on
  /// device. Downloads them if needed (requires internet once).
  /// Returns `true` when the models are ready for offline use.
  Future<bool> ensureModels(Lang source, Lang target) async {
    final src = _mlKitLang(source);
    final tgt = _mlKitLang(target);
    if (src == null || tgt == null) return false;

    final manager = OnDeviceTranslatorModelManager();
    var ok = true;
    for (final model in [src, tgt]) {
      final key = model.name;
      if (_ensuredModels.contains(key)) continue;
      try {
        if (!await manager.isModelDownloaded(model.bcpCode)) {
          ok = ok &&
              await manager.downloadModel(
                model.bcpCode,
                isWifiRequired: false,
              );
        }
        if (ok) _ensuredModels.add(key);
      } catch (e) {
        debugPrint('Translation model download failed for $key: $e');
        return false;
      }
    }
    return ok;
  }

  /// Translate [text] from [source] to [target] fully offline.
  /// Returns `null` when translation is unavailable (unsupported language
  /// pair or model not downloaded).
  Future<String?> translate(String text, Lang source, Lang target) async {
    if (text.trim().isEmpty) return null;
    if (source.iso639 == target.iso639) return text;

    final src = _mlKitLang(source);
    final tgt = _mlKitLang(target);
    if (src == null || tgt == null) return null;

    final key = '${source.iso639}>${target.iso639}';
    try {
      final translator = _translators.putIfAbsent(
        key,
        () => OnDeviceTranslator(sourceLanguage: src, targetLanguage: tgt),
      );
      return await translator.translateText(text);
    } catch (e) {
      debugPrint('Translation failed ($key): $e');
      return null;
    }
  }

  /// Free translator resources.
  Future<void> dispose() async {
    for (final t in _translators.values) {
      try {
        await t.close();
      } catch (_) {}
    }
    _translators.clear();
  }
}
