import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const localePrefsKey = 'locale';

Locale? localeFromPrefs(SharedPreferences prefs) {
  final code = prefs.getString(localePrefsKey);
  return code == null ? null : Locale(code);
}

final initialLocaleProvider = Provider<Locale?>((_) => null);

/// `null` means follow the device.
class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() => ref.watch(initialLocaleProvider);

  Future<void> set(Locale? locale) async {
    if (locale == state) return;
    state = locale;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (locale == null) {
        await prefs.remove(localePrefsKey);
      } else {
        await prefs.setString(localePrefsKey, locale.languageCode);
      }
    } catch (e, st) {
      debugPrint('locale prefs write failed: $e\n$st');
    }
  }
}

final localeProvider = NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
);
