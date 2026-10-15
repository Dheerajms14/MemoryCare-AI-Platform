import 'package:flutter_test/flutter_test.dart';
import 'package:memorycare_offline_demo/translations.dart';

void main() {
  test('all supported languages expose core MemoryCare navigation labels', () {
    for (final language in supportedLanguages) {
      final strings = AppStrings(language.code);
      for (final key in ['app_name', 'home', 'reminders', 'games', 'vault', 'progress']) {
        expect(strings.t(key), isNotEmpty);
        expect(strings.t(key), isNot(key));
      }
    }
  });

  test('replacement values are inserted in translated messages', () {
    expect(AppStrings('en').t('pending_uploads', values: {'count': 3}), contains('3'));
    expect(AppStrings('kn').t('pending_uploads', values: {'count': 2}), contains('2'));
  });
}
