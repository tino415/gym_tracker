import '../data/database.dart';

/// Formats a planned/target set as a compact label for the small watch screen:
/// `"8 × 60 kg"`, `"12 reps"`, `"45s • 20 kg"`, `"30s"`, or `"—"` when the
/// relevant target is missing. Shared by the exercise preview and the rest
/// "up next" line so both render targets identically.
String formatSetTarget({
  required String kind,
  int? reps,
  double? weightKg,
  int? seconds,
}) {
  if (kind == exerciseKindTime) {
    if (seconds == null) return '—';
    if (weightKg != null && weightKg > 0) {
      return '${seconds}s • ${formatWeight(weightKg)} kg';
    }
    return '${seconds}s';
  }
  if (reps == null) return '—';
  if (weightKg == null) return '$reps reps';
  return '$reps × ${formatWeight(weightKg)} kg';
}

/// Trims a trailing `.0` so whole-number weights read `60` not `60.0`.
String formatWeight(double w) =>
    w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
