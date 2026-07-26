import 'package:flutter/material.dart';

import 'round_safe_area.dart';

/// Compact watch-sized "Discard?" confirmation. Renders the routine name as
/// context and presents two large round taps — × to cancel, ✓ to confirm —
/// so the user can hit them without missing on a round face.
///
/// Use [DiscardDialog.show] to show it; the barrier is non-dismissible
/// because an off-target tap on a round watch is too easy to misfire.
class DiscardDialog extends StatelessWidget {
  const DiscardDialog({super.key, required this.routineName});

  final String routineName;

  /// Returns `true` if the user confirmed, `false` otherwise (cancel button —
  /// outside-the-dialog taps can't dismiss).
  static Future<bool> show(
    BuildContext context, {
    required String routineName,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DiscardDialog(routineName: routineName),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isRound = WatchShapeScope.of(context);
    final hInset = isRound ? 28.0 : 12.0;
    return Dialog(
      insetPadding: const EdgeInsets.all(8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(hInset, 12, hInset, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Discard?',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              routineName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.outline,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _RoundChoice(
                  icon: Icons.close,
                  color: scheme.surfaceContainerHighest,
                  iconColor: scheme.onSurface,
                  onTap: () => Navigator.of(context).pop(false),
                ),
                _RoundChoice(
                  icon: Icons.check,
                  color: scheme.errorContainer,
                  iconColor: scheme.onErrorContainer,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Generic compact watch confirmation: a title, an optional subtitle line, and
/// the same two big round taps as [DiscardDialog] (× cancel, ✓ confirm). Used
/// for non-destructive confirms like "Skip exercise?" where the errorContainer
/// accent of the discard dialog would over-signal danger.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  /// Returns `true` if the user confirmed, `false` otherwise (cancel button —
  /// outside-the-dialog taps can't dismiss).
  static Future<bool> show(
    BuildContext context, {
    required String title,
    String? subtitle,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConfirmDialog(title: title, subtitle: subtitle),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isRound = WatchShapeScope.of(context);
    final hInset = isRound ? 28.0 : 12.0;
    return Dialog(
      insetPadding: const EdgeInsets.all(8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(hInset, 12, hInset, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _RoundChoice(
                  icon: Icons.close,
                  color: scheme.surfaceContainerHighest,
                  iconColor: scheme.onSurface,
                  onTap: () => Navigator.of(context).pop(false),
                ),
                _RoundChoice(
                  icon: Icons.check,
                  color: scheme.primaryContainer,
                  iconColor: scheme.onPrimaryContainer,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundChoice extends StatelessWidget {
  const _RoundChoice({
    required this.icon,
    required this.color,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 22, color: iconColor),
        ),
      ),
    );
  }
}
