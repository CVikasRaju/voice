import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/ml/translation_engine.dart';
import 'package:itantra/ml/tts_model_downloader.dart';

void main() {
  group('translation language support', () {
    test('translation is disabled (text-only fallback for APK size reduction)',
        () {
      // ML Kit translation was removed to save ~50 MB in APK.
      // All languages report unsupported — cross-language messages show
      // the original transcribed text instead.
      expect(TranslationEngine.isSupported(kHindi), isFalse);
      expect(TranslationEngine.isSupported(langByIso639('kn')!), isFalse);
      expect(TranslationEngine.isSupported(kEnglish), isFalse);
    });

    test('translate returns null (no ML Kit)', () async {
      final engine = TranslationEngine();
      final result = await engine.translate('hello', kEnglish, kHindi);
      expect(result, isNull);
      await engine.dispose();
    });

    test('same-language translate returns text unchanged', () async {
      final engine = TranslationEngine();
      final result = await engine.translate('hello', kEnglish, kEnglish);
      expect(result, 'hello');
      await engine.dispose();
    });
  });

  group('neural TTS model availability', () {
    test('every Indic language except Odia has an MMS model mapping', () {
      for (final lang in kLanguages) {
        final expected = lang.iso639 != 'or';
        expect(
          TtsModelDownloader.hasNeuralModel(lang),
          expected,
          reason: '${lang.name} (${lang.iso639}) TTS model mapping mismatch',
        );
      }
    });

    test('MMS code mapping is correct', () {
      final hindi = kLanguages.firstWhere((l) => l.iso639 == 'hi');
      expect(hindi.ttsModel, contains('tts'));
      expect(hindi.ttsTokens, contains('tokens'));
    });
  });

  group('language registry', () {
    test('all languages have STT model paths defined', () {
      for (final lang in kLanguages) {
        expect(lang.sttModel, isNotEmpty, reason: '${lang.name} sttModel');
        expect(lang.sttTokens, isNotEmpty, reason: '${lang.name} sttTokens');
      }
    });

    test('language wire IDs are unique (iBFS byte 3 low nibble)', () {
      final wireIds = kLanguages.map((l) => l.wireId).toList();
      expect(wireIds.toSet().length, wireIds.length,
          reason: 'Duplicate wire IDs break iBFS routing');
    });
  });
}
