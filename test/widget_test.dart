// Basic smoke test for iTantra app.

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/theme.dart';
import 'package:itantra/ml/languages.dart';

void main() {
  test('iTantra theme loads', () {
    // Verify the dark theme is accessible.
    final theme = iTantraTheme.dark;
    expect(theme.brightness, isNotNull);
  });

  test('language constants are defined', () {
    expect(kLanguages, isNotEmpty);
    expect(kLanguages.length, greaterThanOrEqualTo(2));
  });
}
