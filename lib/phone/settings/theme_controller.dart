import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the persisted [ThemeMode] as one of
/// `'system' | 'light' | 'dark'`.
const themeModePrefsKey = 'theme_mode';

/// Read the persisted theme mode from [prefs], defaulting to
/// [ThemeMode.system]. Used both by the controller and by `main()` to seed the
/// provider override so the first frame renders in the right theme (no flash).
ThemeMode themeModeFromPrefs(SharedPreferences prefs) =>
    _decode(prefs.getString(themeModePrefsKey));

ThemeMode _decode(String? raw) {
  switch (raw) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

String _encode(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

/// Seed for the theme controller's initial state. `main()` overrides this with
/// the value read from SharedPreferences so the first frame renders in the
/// saved theme (no light→dark flash). Default [ThemeMode.system] applies in
/// tests and any un-overridden scope.
final initialThemeModeProvider = Provider<ThemeMode>((_) => ThemeMode.system);

/// The app's light/dark preference. `PhoneApp` drives `MaterialApp.themeMode`
/// off this; the settings screen writes it. Persisted to SharedPreferences on
/// every change.
///
/// Initial state comes from [initialThemeModeProvider] (seeded in `main()`),
/// which is why there's no flash on launch.
class ThemeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ref.watch(initialThemeModeProvider);

  Future<void> set(ThemeMode mode) async {
    if (mode == state) return;
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(themeModePrefsKey, _encode(mode));
  }
}

final themeModeProvider = NotifierProvider<ThemeController, ThemeMode>(
  ThemeController.new,
);
