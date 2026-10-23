import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'gen/app_localizations.dart';
import 'gen/app_localizations_en.dart';

export 'gen/app_localizations.dart';

const appLocalizationsDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

extension BuildContextL10n on BuildContext {
  /// English when no localizations are mounted, so a bare `MaterialApp` in a
  /// test still renders text.
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      AppLocalizationsEn();
}
