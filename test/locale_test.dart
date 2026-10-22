import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/l10n/l10n.dart';
import 'package:gym_tracker/l10n/language_picker.dart';
import 'package:gym_tracker/l10n/locale_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Locale? locale, Widget home) => ProviderScope(
  overrides: [initialLocaleProvider.overrideWithValue(locale)],
  child: Consumer(
    builder: (context, ref, _) => MaterialApp(
      locale: ref.watch(localeProvider),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: home),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Slovak locale renders Slovak strings', (tester) async {
    await tester.pumpWidget(
      _app(const Locale('sk'), Builder(builder: (c) => Text(c.l10n.language))),
    );
    expect(find.text('Jazyk'), findsOneWidget);
  });

  testWidgets('unsupported device locale falls back to English', (tester) async {
    await tester.pumpWidget(
      _app(const Locale('de'), Builder(builder: (c) => Text(c.l10n.language))),
    );
    expect(find.text('Language'), findsOneWidget);
  });

  testWidgets('picking a language switches the UI and persists it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Locale('en'),
        Column(
          children: [
            const LanguagePicker(),
            Builder(builder: (c) => Text(c.l10n.language)),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slovenčina').last);
    await tester.pumpAndSettle();

    expect(find.text('Jazyk'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(localeFromPrefs(prefs), const Locale('sk'));
  });

  testWidgets('following the device clears the stored choice', (tester) async {
    SharedPreferences.setMockInitialValues({localePrefsKey: 'sk'});
    final container = ProviderContainer(
      overrides: [initialLocaleProvider.overrideWithValue(const Locale('sk'))],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      await container.read(localeProvider.notifier).set(null);
      final prefs = await SharedPreferences.getInstance();
      expect(localeFromPrefs(prefs), isNull);
    });
  });
}
