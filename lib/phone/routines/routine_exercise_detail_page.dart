import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import 'exercise_picker.dart';
import 'planned_set_row.dart';
import 'set_editor_dialog.dart';

/// Detail page for a single routine slot. Owns the full per-exercise editor —
/// planned sets, alternatives, rest, kind, superset toggle, remove. The list
/// page only shows a compact summary; everything write-heavy lives here.
class RoutineExerciseDetailPage extends ConsumerWidget {
  const RoutineExerciseDetailPage({
    super.key,
    required this.routineId,
    required this.routineExerciseId,
  });

  final String routineId;
  final String routineExerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fullAsync = ref.watch(fullRoutineProvider(routineId));
    return Scaffold(
      appBar: AppBar(
        title: fullAsync.when(
          loading: () => const Text('…'),
          error: (_, _) => const Text('Error'),
          data: (full) {
            final re = _find(full);
            return Text(re?.exercise.name ?? '');
          },
        ),
      ),
      body: fullAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (full) {
          final re = _find(full);
          if (re == null || full == null) {
            // Routine exercise was deleted — pop back next frame.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.pop();
            });
            return const SizedBox.shrink();
          }
          return _Body(
            full: full,
            re: re,
          );
        },
      ),
    );
  }

  FullRoutineExercise? _find(FullRoutine? full) {
    if (full == null) return null;
    for (final e in full.exercises) {
      if (e.routineExercise.syncId == routineExerciseId) return e;
    }
    return null;
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.full, required this.re});

  final FullRoutine full;
  final FullRoutineExercise re;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final idx = full.exercises.indexWhere(
      (e) => e.routineExercise.syncId == re.routineExercise.syncId,
    );
    final isFirst = idx == 0;
    final groupedWithPrev = !isFirst &&
        re.routineExercise.supersetGroup != null &&
        re.routineExercise.supersetGroup ==
            full.exercises[idx - 1].routineExercise.supersetGroup;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            Icon(
              re.kind == exerciseKindTime
                  ? Icons.timer_outlined
                  : Icons.repeat,
              size: 20,
            ),
            const SizedBox(width: 8),
            Chip(
              label: Text(
                re.kind == exerciseKindTime ? 'Time' : 'Reps',
              ),
              visualDensity: VisualDensity.compact,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _editRest(context, ref, re.routineExercise),
              icon: const Icon(Icons.timer_outlined, size: 18),
              label: Text('${re.routineExercise.restSeconds}s rest'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!isFirst)
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              selected: groupedWithPrev,
              onSelected: (_) =>
                  _toggleSuperset(ref, full, re, idx),
              label: const Text('Superset with previous'),
              avatar: Icon(
                groupedWithPrev ? Icons.link : Icons.link_off,
                size: 16,
              ),
            ),
          ),
        const Divider(height: 24),
        Row(
          children: [
            Text('Sets', style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _editSetDialog(context, ref, re: re),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add set'),
            ),
          ],
        ),
        if (re.plannedSets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No sets yet — tap Add set to start.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else
          for (var i = 0; i < re.plannedSets.length; i++)
            PlannedSetRow(
              key: ValueKey(re.plannedSets[i].syncId),
              setIndex: i,
              plannedSet: re.plannedSets[i],
              kind: re.kind,
              onEdit: () => _editSetDialog(
                context,
                ref,
                re: re,
                existing: re.plannedSets[i],
              ),
              onDelete: () => ref
                  .read(routineRepositoryProvider)
                  .deletePlannedSet(re.plannedSets[i].syncId),
            ),
        const Divider(height: 24),
        Row(
          children: [
            Icon(Icons.swap_horiz, size: 18, color: theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text('Alternatives', style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _addAlternative(context, ref, re),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        if (re.alternatives.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
            child: Text(
              'Swap targets at workout time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else
          for (final alt in re.alternatives)
            _AlternativeTile(
              parentKind: re.kind,
              alternative: alt,
              onDelete: () => ref
                  .read(routineRepositoryProvider)
                  .removeRoutineExerciseAlternative(alt.join.syncId),
              onAddSet: () => _editAltSetDialog(context, ref, alt: alt),
              onEditSet: (s) =>
                  _editAltSetDialog(context, ref, alt: alt, existing: s),
              onDeleteSet: (s) => ref
                  .read(routineRepositoryProvider)
                  .deleteAlternativePlannedSet(s.syncId),
            ),
        const Divider(height: 32),
        OutlinedButton.icon(
          onPressed: () => _confirmRemove(context, ref, re),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Remove from routine'),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
        ),
      ],
    );
  }
}

Future<void> _confirmRemove(
  BuildContext context,
  WidgetRef ref,
  FullRoutineExercise re,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Remove exercise?'),
      content: Text(
        'Remove ${re.exercise.name} from this routine? Past workouts keep their copy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await ref.read(routineRepositoryProvider).removeRoutineExercise(re.routineExercise.syncId);
  if (!context.mounted) return;
  context.pop();
}

Future<void> _editRest(
  BuildContext context,
  WidgetRef ref,
  RoutineExercise re,
) async {
  final controller = TextEditingController(text: re.restSeconds.toString());
  final result = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rest between sets'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(suffixText: 'seconds'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final parsed = int.tryParse(controller.text.trim());
            Navigator.of(ctx).pop(parsed);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // Guard against the page unmounting during the dialog await (e.g. a
  // concurrent sync bundle-apply pops it): using ref/context afterwards throws.
  if (result != null && result > 0 && context.mounted) {
    await ref.read(routineRepositoryProvider).setRestSeconds(re.syncId, result);
  }
}

Future<void> _toggleSuperset(
  WidgetRef ref,
  FullRoutine full,
  FullRoutineExercise current,
  int idx,
) async {
  if (idx == 0) return; // first slot has no previous to group with
  final db = ref.read(routineRepositoryProvider);
  final prev = full.exercises[idx - 1];
  final currentGroup = current.routineExercise.supersetGroup;
  if (currentGroup != null &&
      currentGroup == prev.routineExercise.supersetGroup) {
    await db.setSupersetGroup(current.routineExercise.syncId, null);
    return;
  }
  int group;
  if (prev.routineExercise.supersetGroup != null) {
    group = prev.routineExercise.supersetGroup!;
  } else {
    var max = 0;
    for (final re in full.exercises) {
      final g = re.routineExercise.supersetGroup;
      if (g != null && g > max) max = g;
    }
    group = max + 1;
    await db.setSupersetGroup(prev.routineExercise.syncId, group);
  }
  await db.setSupersetGroup(current.routineExercise.syncId, group);
}

Future<void> _addAlternative(
  BuildContext context,
  WidgetRef ref,
  FullRoutineExercise re,
) async {
  final excludeIds = <String>{
    re.exercise.syncId,
    ...re.alternatives.map((a) => a.exercise.syncId),
  };
  final picked = await showExercisePicker(
    context,
    ref,
    excludeIds: excludeIds,
  );
  // Guard: the picker await may outlive the page (a concurrent sync
  // bundle-apply can pop it), and ref.read on a defunct ref throws.
  if (picked == null || !context.mounted) return;
  await ref.read(routineRepositoryProvider).addRoutineExerciseAlternative(
        routineExerciseId: re.routineExercise.syncId,
        exerciseId: picked.syncId,
      );
}

void _editSetDialog(
  BuildContext context,
  WidgetRef ref, {
  required FullRoutineExercise re,
  PlannedSet? existing,
}) {
  final db = ref.read(routineRepositoryProvider);
  final reId = re.routineExercise.syncId;
  showDialog<void>(
    context: context,
    builder: (_) => SetEditorDialog(
      kind: re.kind,
      existingId: existing?.syncId,
      initialReps: existing?.targetReps,
      initialWeightKg: existing?.targetWeightKg,
      initialSeconds: existing?.targetSeconds,
      onAdd: (v) => db.addPlannedSet(
        routineExerciseId: reId,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
      onUpdate: (id, v) => db.updatePlannedSet(
        id: id,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
    ),
  );
}

void _editAltSetDialog(
  BuildContext context,
  WidgetRef ref, {
  required RoutineAlternative alt,
  AlternativePlannedSet? existing,
}) {
  final db = ref.read(routineRepositoryProvider);
  final altId = alt.join.syncId;
  showDialog<void>(
    context: context,
    builder: (_) => SetEditorDialog(
      kind: alt.exercise.kind,
      existingId: existing?.syncId,
      initialReps: existing?.targetReps,
      initialWeightKg: existing?.targetWeightKg,
      initialSeconds: existing?.targetSeconds,
      onAdd: (v) => db.addAlternativePlannedSet(
        alternativeId: altId,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
      onUpdate: (id, v) => db.updateAlternativePlannedSet(
        id: id,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
    ),
  );
}

class _AlternativeTile extends StatelessWidget {
  const _AlternativeTile({
    required this.parentKind,
    required this.alternative,
    required this.onDelete,
    required this.onAddSet,
    required this.onEditSet,
    required this.onDeleteSet,
  });

  final String parentKind;
  final RoutineAlternative alternative;
  final VoidCallback onDelete;
  final VoidCallback onAddSet;
  final void Function(AlternativePlannedSet) onEditSet;
  final void Function(AlternativePlannedSet) onDeleteSet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ex = alternative.exercise;
    final ps = alternative.plannedSets;
    final hint = ps.isEmpty
        ? 'uses primary targets'
        : ps.length == 1
            ? '1 set'
            : '${ps.length} sets';
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(
          ex.kind == exerciseKindTime ? Icons.timer_outlined : Icons.repeat,
          size: 18,
        ),
        title: Text(ex.name, style: theme.textTheme.bodyLarge),
        subtitle: Text(
          hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        trailing: IconButton(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: 'Remove alternative',
        ),
        childrenPadding: const EdgeInsets.only(left: 12, right: 4, bottom: 8),
        children: [
          for (var i = 0; i < ps.length; i++)
            _AlternativePlannedSetRow(
              index: i,
              kind: ex.kind,
              set: ps[i],
              onEdit: () => onEditSet(ps[i]),
              onDelete: () => onDeleteSet(ps[i]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAddSet,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add set'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlternativePlannedSetRow extends StatelessWidget {
  const _AlternativePlannedSetRow({
    required this.index,
    required this.kind,
    required this.set,
    required this.onEdit,
    required this.onDelete,
  });

  final int index;
  final String kind;
  final AlternativePlannedSet set;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String _describe() {
    if (kind == exerciseKindTime) {
      final s = set.targetSeconds;
      final w = set.targetWeightKg;
      if (s == null && w == null) return '—';
      final parts = <String>[];
      if (s != null) parts.add('${s}s');
      if (w != null && w > 0) parts.add('${_fmt(w)} kg');
      return parts.join(' · ');
    }
    final r = set.targetReps;
    final w = set.targetWeightKg;
    if (r == null && w == null) return '—';
    final parts = <String>[];
    if (r != null) parts.add('$r reps');
    if (w != null) parts.add('${_fmt(w)} kg');
    return parts.join(' · ');
  }

  String _fmt(double w) =>
      w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${index + 1}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ),
            Expanded(child: Text(_describe())),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Remove set',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
