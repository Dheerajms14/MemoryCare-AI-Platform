import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/auth_screen.dart';
import '../lib/auth_service.dart';

void main() {
  test('production-oriented URL validation rejects credentials and cleartext', () {
    expect(checkedServerUrl('https://memorycare.example/'), 'https://memorycare.example');
    expect(() => checkedServerUrl('https://name:secret@memorycare.example'), throwsA(isA<AuthException>()));
    expect(() => checkedServerUrl('https://memorycare.example/path'), throwsA(isA<AuthException>()));
    expect(() => checkedServerUrl('https://memorycare.example?token=secret'), throwsA(isA<AuthException>()));
    if (!allowLocalHttp) expect(() => checkedServerUrl('http://memorycare.example'), throwsA(isA<AuthException>()));
  });

  testWidgets('login starts without demo credentials and validates empty form', (tester) async {
    final server = TextEditingController(text: 'https://memorycare.example');
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: AuthenticationScreen(languageCode: 'en', server: server,
      onLanguageChanged: (_) async {}, onSubmit: (role, username, password, name) async { calls++; })));
    expect(find.text('demo1234'), findsNothing);
    expect(find.text('Patient'), findsOneWidget);
    expect(find.text('Caregiver'), findsOneWidget);
    final submit = find.byWidgetPredicate((widget) => widget is FilledButton);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(calls, 0);
    expect(find.text('This field is required.'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    server.dispose();
  });
}
