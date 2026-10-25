import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/l10n/l10n.dart';
import 'package:gym_tracker/l10n/language_picker.dart';
import 'package:gym_tracker/l10n/locale_controller.dart';
import 'package:gym_tracker/phone/sign_in_screen.dart';

void main() {
  testWidgets(
    'language picker is a full-width footer below the sign-in actions',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialLocaleProvider.overrideWithValue(const Locale('en')),
          ],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SignInScreen(),
          ),
        ),
      );

      final picker = tester.getRect(find.byType(LanguagePicker));
      final createAccount = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Create account'),
      );
      final signIn = tester.getRect(find.byType(FilledButton));

      expect(picker.top, greaterThan(createAccount.bottom));
      expect(picker.width, signIn.width);
    },
  );

  testWidgets('language picker is labelled and visible on a phone screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialLocaleProvider.overrideWithValue(const Locale('en')),
        ],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SignInScreen(),
        ),
      ),
    );

    expect(find.text('Language'), findsOneWidget);
    final picker = tester.getRect(find.byType(LanguagePicker));
    expect(picker.bottom, lessThanOrEqualTo(640));
  });
}
