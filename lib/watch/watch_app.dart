import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../l10n/locale_controller.dart';
import 'watch_pick_routine_page.dart';

class WatchApp extends ConsumerWidget {
  const WatchApp({super.key, this.ambient = false});

  final bool ambient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'GymTracker',
      locale: ref.watch(localeProvider),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: watchTheme(),
      home: ambient ? const _AmbientFace() : const WatchPickRoutinePage(),
    );
  }
}

/// The watch is dark unconditionally — there is no setting, unlike the phone.
ThemeData watchTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
      brightness: Brightness.dark,
    ),
    // True black rather than Material's dark grey: on OLED these pixels are
    // off for a whole session, and it makes the transition into the ambient
    // face continuous instead of a flash.
    scaffoldBackgroundColor: Colors.black,
    useMaterial3: true,
  );
}

class _AmbientFace extends StatelessWidget {
  const _AmbientFace();

  @override
  Widget build(BuildContext context) {
    // white70 rather than a theme colour: ambient renders dimmer than the
    // interactive UI on purpose, for burn-in and power.
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Text('GymTracker', style: TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }
}
