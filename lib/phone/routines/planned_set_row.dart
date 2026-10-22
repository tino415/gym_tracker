import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../l10n/l10n.dart';
import '../number_format.dart';

/// Read-only display of a planned set. Tapping opens an edit dialog managed
/// by the parent; the row itself never writes to the DB so changes follow
/// the explicit-save model.
class PlannedSetRow extends StatelessWidget {
  const PlannedSetRow({
    super.key,
    required this.setIndex,
    required this.plannedSet,
    required this.kind,
    required this.onEdit,
    required this.onDelete,
  });

  final int setIndex;
  final PlannedSet plannedSet;
  final String kind;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String _describe(BuildContext context) {
    if (kind == exerciseKindTime) {
      final s = plannedSet.targetSeconds ?? 0;
      final w = plannedSet.targetWeightKg;
      if (w == null || w == 0) return context.l10n.commonSecondsValue(s);
      return context.l10n.commonSecondsAtWeight(s, formatKg(context, w));
    }
    final reps = plannedSet.targetReps ?? 0;
    final kg = plannedSet.targetWeightKg ?? 0;
    return context.l10n.commonWeightTimesReps(formatKg(context, kg), reps);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Text(
                '${setIndex + 1}.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: Text(
                _describe(context),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.close),
              tooltip: context.l10n.routineRemoveSet,
            ),
          ],
        ),
      ),
    );
  }
}
