import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import 'muscle_label.dart';

/// Multi-select chip list of muscle groups, shared by the exercise editor
/// ([ExerciseEditPage]) and the inline "Create new exercise" dialog in the
/// routine exercise picker. Reads [musclesStreamProvider]; renders nothing
/// while muscles load or if the registry is empty. [selectedIds] is owned by
/// the caller and mutated via [onToggled], which fires the tapped muscle's id.
class MuscleSelector extends ConsumerWidget {
  const MuscleSelector({
    super.key,
    required this.selectedIds,
    required this.onToggled,
  });

  final Set<String> selectedIds;
  final ValueChanged<String> onToggled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final musclesAsync = ref.watch(musclesStreamProvider);
    return musclesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text(context.l10n.exerciseMusclesLoadError('$e')),
      data: (muscles) {
        if (muscles.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.exerciseMusclesTitle, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final m in muscles)
                  FilterChip(
                    label: Text(muscleLabel(context.l10n, m.name)),
                    selected: selectedIds.contains(m.syncId),
                    onSelected: (_) => onToggled(m.syncId),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
