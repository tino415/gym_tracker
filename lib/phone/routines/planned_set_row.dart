import 'package:flutter/material.dart';

import '../../data/database.dart';

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

  String _formatWeight(double w) {
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }

  String _describe() {
    if (kind == exerciseKindTime) {
      final s = plannedSet.targetSeconds ?? 0;
      final w = plannedSet.targetWeightKg;
      if (w == null || w == 0) return '$s s';
      return '$s s @ ${_formatWeight(w)} kg';
    }
    final reps = plannedSet.targetReps ?? 0;
    final kg = plannedSet.targetWeightKg ?? 0;
    return '${_formatWeight(kg)} kg × $reps';
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
                _describe(),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.close),
              tooltip: 'Remove set',
            ),
          ],
        ),
      ),
    );
  }
}
