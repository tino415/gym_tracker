import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../l10n/l10n.dart';

/// Formats a set's reps, weight and seconds, planned or logged, as a compact
/// label for the small watch screen:
/// `"8 × 60 kg"`, `"12 reps"`, `"45s • 20 kg"`, `"30s"`, or `"—"` when the
/// relevant target is missing. Shared by the exercise preview and the rest
/// "up next" line so both render targets identically.
String formatSetTarget(
  BuildContext context, {
  required String kind,
  int? reps,
  double? weightKg,
  int? seconds,
}) {
  final l10n = context.l10n;
  final locale = Localizations.localeOf(context).toString();
  if (kind == exerciseKindTime) {
    if (seconds == null) return '—';
    if (weightKg != null && weightKg > 0) {
      return l10n.watchTargetSecondsWeight(
        seconds,
        formatWeight(weightKg, locale: locale),
      );
    }
    return l10n.watchSecondsShort(seconds);
  }
  if (reps == null) return '—';
  if (weightKg == null) return l10n.watchTargetReps(reps);
  return l10n.watchTargetRepsWeight(
    reps,
    formatWeight(weightKg, locale: locale),
  );
}

/// Trims a trailing `.0` so whole-number weights read `60` not `60.0`, with
/// the decimal separator of [locale].
String formatWeight(double w, {String? locale}) {
  final text =
      w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  if (locale == null) return text;
  return text.replaceAll(
    '.',
    NumberFormat.decimalPattern(locale).symbols.DECIMAL_SEP,
  );
}
