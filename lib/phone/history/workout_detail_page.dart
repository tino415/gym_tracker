import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import '../routines/exercise_picker.dart';
import '../circuit_units.dart';

class WorkoutDetailPage extends ConsumerStatefulWidget {
  const WorkoutDetailPage({
    super.key,
    required this.workoutId,
    this.embedded = false,
    this.onDeleted,
  });

  final String workoutId;

  /// Hosted in the wide master-detail pane rather than pushed as a route: no
  /// back stack, so delete reports out via [onDeleted] instead of popping.
  final bool embedded;

  /// Called when an embedded editor deletes its workout (clears the selection).
  final VoidCallback? onDeleted;

  @override
  ConsumerState<WorkoutDetailPage> createState() => _WorkoutDetailPageState();
}

class _WorkoutDetailPageState extends ConsumerState<WorkoutDetailPage> {
  @override
  Widget build(BuildContext context) {
    final asyncSnap = ref.watch(fullWorkoutProvider(widget.workoutId));
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(context.l10n.historyDetailTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: context.l10n.historyDeleteWorkout,
            onPressed: () => _deleteWorkout(context),
          ),
        ],
      ),
      body: asyncSnap.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(context.l10n.historyError('$e'))),
        data: (snap) {
          if (snap == null) {
            return Center(child: Text(context.l10n.historyNotFound));
          }
          return _Body(snap: snap);
        },
      ),
    );
  }

  Future<void> _deleteWorkout(BuildContext context) async {
    final router = GoRouter.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.historyDeleteTitle),
        content: Text(ctx.l10n.historyDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.l10n.historyCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.l10n.historyDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(workoutRepositoryProvider).deleteWorkout(widget.workoutId);
    if (!mounted) return;
    if (widget.embedded) {
      widget.onDeleted?.call();
    } else {
      router.pop();
    }
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.snap});

  final FullWorkout snap;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _reorderMode = false;

  FullWorkout get snap => widget.snap;

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(workoutRepositoryProvider);
    // Circuits are positional: consecutive exercises sharing a group are one.
    // Reordering therefore moves whole units, so a drag can never interleave
    // two groups and silently change what the workout means.
    final units = buildCircuitUnits<FullWorkoutExercise>(
      snap.exercises,
      (e) => e.workoutExercise.circuitGroup,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        _ImprovementsBanner(
          workoutId: snap.workout.syncId,
          version: snap.workout.version,
        ),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(context.l10n.historyStarted),
                subtitle: _StampRow(
                  value: snap.workout.startedAt,
                  onEditDate: () => _editStamp(context, ref, isStart: true, date: true),
                  onEditTime: () => _editStamp(context, ref, isStart: true, date: false),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.stop_outlined),
                title: Text(context.l10n.historyEnded),
                subtitle: snap.workout.endedAt == null
                    // No timestamp to split yet, so offer the full flow.
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () =>
                              _editStamp(context, ref, isStart: false, date: true, thenTime: true),
                          child: Text(context.l10n.historyInProgressSetEnd),
                        ),
                      )
                    : _StampRow(
                        value: snap.workout.endedAt!,
                        onEditDate: () => _editStamp(context, ref, isStart: false, date: true),
                        onEditTime: () => _editStamp(context, ref, isStart: false, date: false),
                      ),
              ),
              if (snap.routine != null)
                ListTile(
                  leading: const Icon(Icons.fitness_center),
                  title: Text(context.l10n.historyRoutine),
                  subtitle: Text(snap.routine!.name),
                ),
              if (snap.workout.avgHeartRate != null ||
                  snap.workout.maxHeartRate != null) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.favorite, color: Colors.redAccent),
                  title: Text(context.l10n.historyHeartRate),
                  subtitle: Text(
                    _hrLine(
                      context,
                      snap.workout.avgHeartRate,
                      snap.workout.maxHeartRate,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (snap.exercises.length > 1)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _reorderMode = !_reorderMode),
              icon: Icon(_reorderMode ? Icons.check : Icons.swap_vert),
              label: Text(
                _reorderMode
                    ? context.l10n.historyDone
                    : context.l10n.historyReorder,
              ),
            ),
          ),
        if (_reorderMode)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: units.length,
            itemBuilder: (context, idx) => _ReorderUnitTile(
              key: ValueKey(units[idx].first.workoutExercise.syncId),
              unit: units[idx],
              index: idx,
              onInnerReorder: (o, n) => _reorderInside(units, idx, o, n),
            ),
            onReorder: (o, n) => _reorderUnits(units, o, n),
          )
        else
          for (final unit in units) ...[
            if (unit.isGroup) const _CircuitHeader(),
            for (final ex in unit.members) ...[
              _ExerciseSection(
                ex: ex,
                inCircuit: unit.isGroup,
                onAddSet: () => _addSet(context, ref, ex),
                onSwapExercise: () => _swapExercise(context, ref, ex),
                onRemoveExercise: () => _removeExercise(context, ref, ex),
                onEditCompletion: (set) =>
                    _editCompletion(context, ref, ex: ex, set: set),
                onRemoveCompletion: (id) => db.deleteCompletion(id),
                onRemoveSet: (id) => db.removeWorkoutSet(id),
              ),
              const SizedBox(height: 12),
            ],
          ],
        if (!_reorderMode)
          Center(
            child: TextButton.icon(
              onPressed: () => _addExercise(context, ref),
              icon: const Icon(Icons.add),
              label: Text(context.l10n.historyAddExercise),
            ),
          ),
      ],
    );
  }

  Future<void> _reorderUnits(
    List<CircuitUnit<FullWorkoutExercise>> units,
    int oldIndex,
    int newIndex,
  ) => ref.read(workoutRepositoryProvider).reorderWorkoutExercises(
    workoutId: snap.workout.syncId,
    orderedIds: reorderUnits(
      units,
      oldIndex,
      newIndex,
      (e) => e.workoutExercise.syncId,
    ),
  );

  Future<void> _reorderInside(
    List<CircuitUnit<FullWorkoutExercise>> units,
    int unitIndex,
    int oldIndex,
    int newIndex,
  ) => ref.read(workoutRepositoryProvider).reorderWorkoutExercises(
    workoutId: snap.workout.syncId,
    orderedIds: reorderWithinUnit(
      units,
      unitIndex,
      oldIndex,
      newIndex,
      (e) => e.workoutExercise.syncId,
    ),
  );

  /// Edit one half of a timestamp. [date] picks which picker opens, so the
  /// time is reachable in one tap instead of only after dismissing a date
  /// dialog. [thenTime] chains both, for a workout with no end time yet —
  /// there's no existing value to keep, so both halves have to be chosen.
  Future<void> _editStamp(
    BuildContext context,
    WidgetRef ref, {
    required bool isStart,
    required bool date,
    bool thenTime = false,
  }) async {
    final initial = isStart ? snap.workout.startedAt : snap.workout.endedAt;
    final base = initial ?? DateTime.now();
    var merged = base;

    if (date) {
      final picked = await showDatePicker(
        context: context,
        initialDate: base,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (picked == null) return;
      merged = DateTime(
        picked.year,
        picked.month,
        picked.day,
        base.hour,
        base.minute,
      );
      if (!thenTime) return _writeStamp(ref, isStart: isStart, value: merged);
      if (!context.mounted) return;
    }

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return;
    merged = DateTime(
      merged.year,
      merged.month,
      merged.day,
      time.hour,
      time.minute,
    );
    return _writeStamp(ref, isStart: isStart, value: merged);
  }

  Future<void> _writeStamp(
    WidgetRef ref, {
    required bool isStart,
    required DateTime value,
  }) async {
    final merged = value;
    final db = ref.read(workoutRepositoryProvider);
    await db.updateWorkoutTimes(
      workoutId: snap.workout.syncId,
      startedAt: isStart ? merged : snap.workout.startedAt,
      endedAt: isStart ? snap.workout.endedAt : merged,
    );
  }

  Future<void> _addSet(
    BuildContext context,
    WidgetRef ref,
    FullWorkoutExercise ex,
  ) async {
    // A finished workout is a record of what happened, so a set added here is
    // something the user *did* — capture it as a completion too. Without that
    // it lands as a bare target and renders as an unfinished set. An
    // in-progress workout keeps the old meaning: a set added there is a plan.
    final finished = snap.workout.endedAt != null;
    final values = await _showSetEditDialog(
      context,
      kind: ex.kind,
      reps: null,
      weightKg: null,
      seconds: null,
      title: finished
          ? context.l10n.historyAddCompletedSet
          : context.l10n.historyAddSet,
    );
    if (values == null) return;
    final db = ref.read(workoutRepositoryProvider);
    final set = await db.addWorkoutSet(
      workoutExerciseId: ex.workoutExercise.syncId,
      targetReps: values.$1,
      targetWeightKg: values.$2,
      targetSeconds: values.$3,
    );
    if (!finished) return;
    await db.upsertSetCompletion(
      workoutId: snap.workout.syncId,
      workoutSetId: set.syncId,
      actualReps: values.$1,
      actualWeightKg: values.$2,
      actualSeconds: values.$3,
    );
  }

  Future<void> _removeExercise(
    BuildContext context,
    WidgetRef ref,
    FullWorkoutExercise ex,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.historyRemoveExerciseTitle),
        content: Text(
          ctx.l10n.historyRemoveExerciseBody(ex.workoutExercise.exerciseName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.l10n.historyCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.l10n.historyRemove),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(workoutRepositoryProvider).removeWorkoutExercise(ex.workoutExercise.syncId);
  }

  Future<void> _editCompletion(
    BuildContext context,
    WidgetRef ref, {
    required FullWorkoutExercise ex,
    required FullWorkoutSet set,
  }) async {
    final c = set.completion;
    final values = await _showSetEditDialog(
      context,
      kind: ex.kind,
      reps: c?.actualReps ?? set.workoutSet.targetReps,
      weightKg: c?.actualWeightKg ?? set.workoutSet.targetWeightKg,
      seconds: c?.actualSeconds ?? set.workoutSet.targetSeconds,
      title: c == null
          ? context.l10n.historyAddCompletion
          : context.l10n.historyEditCompletion,
    );
    if (values == null) return;
    final db = ref.read(workoutRepositoryProvider);
    if (c == null) {
      await db.upsertSetCompletion(
        workoutId: snap.workout.syncId,
        workoutSetId: set.workoutSet.syncId,
        actualReps: values.$1,
        actualWeightKg: values.$2,
        actualSeconds: values.$3,
      );
    } else {
      await db.updateCompletion(
        id: c.syncId,
        actualReps: values.$1,
        actualWeightKg: values.$2,
        actualSeconds: values.$3,
      );
    }
  }

  /// Swap which exercise this slot records, keeping its sets and completions —
  /// for when the machine you planned on was occupied.
  ///
  /// The picker is narrowed to the same kind: the sets carry over untouched, so
  /// swapping a reps exercise for a time one would leave every target blank.
  Future<void> _swapExercise(
    BuildContext context,
    WidgetRef ref,
    FullWorkoutExercise ex,
  ) async {
    final current = ex.workoutExercise.exerciseId;
    final picked = await showExercisePicker(
      context,
      ref,
      kind: ex.kind,
      excludeIds: {?current},
      markCounts: countExerciseIds(
        snap.exercises.map((e) => e.workoutExercise.exerciseId),
      ),
      markLabel: context.l10n.historyInThisWorkout,
    );
    if (picked == null) return;
    await ref.read(workoutRepositoryProvider).changeWorkoutExercise(
          workoutExerciseId: ex.workoutExercise.syncId,
          exerciseId: picked.syncId,
        );
  }

  Future<void> _addExercise(BuildContext context, WidgetRef ref) async {
    final workouts = ref.read(workoutRepositoryProvider);
    // The routine editor's picker — name search, muscle filters, and a "Create
    // new exercise" tile. The workout editor used to roll its own list, which
    // is why an exercise could not be created while adding one here. No
    // excludeIds: repeating an exercise within a workout is legitimate.
    final picked = await showExercisePicker(
      context,
      ref,
      markCounts: countExerciseIds(
        snap.exercises.map((e) => e.workoutExercise.exerciseId),
      ),
      markLabel: context.l10n.historyInThisWorkout,
    );
    if (picked == null) return;
    await workouts.addWorkoutExercise(
      workoutId: snap.workout.syncId,
      exerciseId: picked.syncId,
    );
  }

  static String _hrLine(BuildContext context, int? avg, int? max) {
    final l10n = context.l10n;
    if (avg != null && max != null) return l10n.historyHrAvgMax(avg, max);
    if (avg != null) return l10n.historyHrAvg(avg);
    return l10n.historyHrMax(max!);
  }
}

/// Labels a run of exercises that form a circuit, so reordering them as one
/// block reads as deliberate rather than as the list refusing to move.
class _CircuitHeader extends StatelessWidget {
  const _CircuitHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 4),
      child: Row(
        children: [
          Icon(Icons.link, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            context.l10n.historyCircuit,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// One draggable row in reorder mode: a lone exercise, or a circuit block
/// whose members can be dragged among themselves but never out of the block.
class _ReorderUnitTile extends StatelessWidget {
  const _ReorderUnitTile({
    super.key,
    required this.unit,
    required this.index,
    required this.onInnerReorder,
  });

  final CircuitUnit<FullWorkoutExercise> unit;
  final int index;
  final void Function(int oldIndex, int newIndex) onInnerReorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!unit.isGroup) {
      return Card(
        key: ValueKey('u-${unit.first.workoutExercise.syncId}'),
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: ReorderableDragStartListener(
            index: index,
            child: const Icon(Icons.drag_handle),
          ),
          title: Text(unit.first.workoutExercise.exerciseName),
        ),
      );
    }
    return Card(
      key: ValueKey('u-${unit.first.workoutExercise.syncId}'),
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                  const SizedBox(width: 12),
                  const _CircuitHeader(),
                ],
              ),
            ),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: unit.members.length,
              itemBuilder: (context, i) => ListTile(
                key: ValueKey('m-${unit.members[i].workoutExercise.syncId}'),
                dense: true,
                leading: ReorderableDragStartListener(
                  index: i,
                  child: const Icon(Icons.drag_indicator, size: 18),
                ),
                title: Text(unit.members[i].workoutExercise.exerciseName),
              ),
              onReorder: onInnerReorder,
            ),
          ],
        ),
      ),
    );
  }
}

class _ExerciseSection extends ConsumerWidget {
  const _ExerciseSection({
    required this.ex,
    this.inCircuit = false,
    required this.onAddSet,
    required this.onSwapExercise,
    required this.onRemoveExercise,
    required this.onEditCompletion,
    required this.onRemoveCompletion,
    required this.onRemoveSet,
  });

  final FullWorkoutExercise ex;

  /// Indents the card so a circuit's members read as one block.
  final bool inCircuit;
  final VoidCallback onAddSet;
  final VoidCallback onSwapExercise;
  final VoidCallback onRemoveExercise;
  final void Function(FullWorkoutSet set) onEditCompletion;
  final void Function(String completionId) onRemoveCompletion;
  final void Function(String workoutSetId) onRemoveSet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final exerciseId = ex.workoutExercise.exerciseId;
    return Card(
      margin: inCircuit
          ? const EdgeInsets.only(left: 12)
          : EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  ex.kind == exerciseKindTime
                      ? Icons.timer_outlined
                      : Icons.repeat,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    ex.workoutExercise.exerciseName,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: onSwapExercise,
                  icon: const Icon(Icons.swap_horiz),
                  tooltip: context.l10n.historySwapExercise,
                ),
                IconButton(
                  onPressed: onRemoveExercise,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: context.l10n.historyRemoveExercise,
                ),
              ],
            ),
            if (exerciseId != null) _MuscleChipsRow(exerciseId: exerciseId),
            const Divider(),
            for (var i = 0; i < ex.sets.length; i++)
              _SetRow(
                index: i,
                set: ex.sets[i],
                kind: ex.kind,
                onEdit: () => onEditCompletion(ex.sets[i]),
                onRemoveCompletion: ex.sets[i].completion == null
                    ? null
                    : () => onRemoveCompletion(ex.sets[i].completion!.syncId),
                onRemoveSet: () => onRemoveSet(ex.sets[i].workoutSet.syncId),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAddSet,
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.l10n.historyAddSet),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MuscleChipsRow extends ConsumerWidget {
  const _MuscleChipsRow({required this.exerciseId});

  final String exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exercises = ref.watch(exerciseRepositoryProvider);
    return FutureBuilder<List<Muscle>>(
      future: exercises.musclesForExercise(exerciseId),
      builder: (context, snap) {
        final list = snap.data ?? const <Muscle>[];
        if (list.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final m in list)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    m.name,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SetRow extends StatelessWidget {
  const _SetRow({
    required this.index,
    required this.set,
    required this.kind,
    required this.onEdit,
    required this.onRemoveCompletion,
    required this.onRemoveSet,
  });

  final int index;
  final FullWorkoutSet set;
  final String kind;
  final VoidCallback onEdit;
  final VoidCallback? onRemoveCompletion;
  final VoidCallback onRemoveSet;

  @override
  Widget build(BuildContext context) {
    final completion = set.completion;
    final missing = completion == null;
    final theme = Theme.of(context);
    final l10n = context.l10n;
    String descActual;
    String descTarget;
    if (kind == exerciseKindTime) {
      if (completion?.actualSeconds == null) {
        descActual = '—';
      } else {
        final s = completion!.actualSeconds!;
        final w = completion.actualWeightKg;
        descActual = w == null || w == 0
            ? l10n.historySecondsActual(s)
            : l10n.historySecondsWeightActual(s, _weightText(context, w));
      }
      final ts = set.workoutSet.targetSeconds;
      final tw = set.workoutSet.targetWeightKg;
      if (ts == null) {
        descTarget = '';
      } else if (tw == null || tw == 0) {
        descTarget = l10n.historySecondsTarget(ts);
      } else {
        descTarget =
            l10n.historySecondsWeightTarget(ts, _weightText(context, tw));
      }
    } else {
      // Bodyweight sets carry reps and no weight. Both halves below drop the
      // weight when there isn't one, rather than inventing "0 kg" or going
      // blank — the time branch above already degrades the same way.
      if (completion == null) {
        descActual = '—';
      } else {
        final w = completion.actualWeightKg;
        final reps = completion.actualReps ?? 0;
        descActual = (w == null || w == 0)
            ? l10n.historyRepsActual(reps)
            : l10n.historyWeightRepsActual(_weightText(context, w), reps);
      }
      final tw = set.workoutSet.targetWeightKg;
      final tr = set.workoutSet.targetReps;
      if (tr == null) {
        descTarget = '';
      } else if (tw == null || tw == 0) {
        descTarget = l10n.historyRepsTarget(tr);
      } else {
        descTarget =
            l10n.historyWeightRepsTarget(_weightText(context, tw), tr);
      }
    }
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Text(
                '${index + 1}.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    descActual,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: missing ? theme.colorScheme.outline : null,
                    ),
                  ),
                  if (descTarget.isNotEmpty)
                    Text(
                      descTarget,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  if (completion?.avgHeartRate != null ||
                      completion?.maxHeartRate != null)
                    Row(
                      children: [
                        Icon(
                          Icons.favorite,
                          size: 12,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _setHrLine(
                            context,
                            completion?.avgHeartRate,
                            completion?.maxHeartRate,
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (onRemoveCompletion != null)
              IconButton(
                onPressed: onRemoveCompletion,
                icon: const Icon(Icons.remove_circle_outline),
                tooltip: context.l10n.historyRemoveCompletion,
              ),
            IconButton(
              onPressed: onRemoveSet,
              icon: const Icon(Icons.close),
              tooltip: context.l10n.historyRemoveSet,
            ),
          ],
        ),
      ),
    );
  }
}

String _setHrLine(BuildContext context, int? avg, int? max) {
  final l10n = context.l10n;
  if (avg != null && max != null) return l10n.historySetHrAvgMax(avg, max);
  if (avg != null) return l10n.historySetHrAvg(avg);
  return l10n.historySetHrMax(max!);
}

/// Returns (reps, weightKg, seconds) — at most two of them are non-null,
/// depending on [kind]. Null overall means the user cancelled.
/// A timestamp shown as two separately tappable halves, so changing just the
/// time doesn't mean walking through a date picker first.
class _StampRow extends StatelessWidget {
  const _StampRow({
    required this.value,
    required this.onEditDate,
    required this.onEditTime,
  });

  final DateTime value;
  final VoidCallback onEditDate;
  final VoidCallback onEditTime;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final dateLabel =
        DateFormat(context.l10n.historyDatePattern, locale).format(value);
    final timeLabel = DateFormat('HH:mm', locale).format(value);
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 4,
        children: [
          _StampChip(
            icon: Icons.event_outlined,
            label: dateLabel,
            tooltip: context.l10n.historyChangeDate,
            onTap: onEditDate,
          ),
          _StampChip(
            icon: Icons.schedule_outlined,
            label: timeLabel,
            tooltip: context.l10n.historyChangeTime,
            onTap: onEditTime,
          ),
        ],
      ),
    );
  }
}

class _StampChip extends StatelessWidget {
  const _StampChip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16),
              const SizedBox(width: 4),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}

Future<(int?, double?, int?)?> _showSetEditDialog(
  BuildContext context, {
  required String kind,
  required int? reps,
  required double? weightKg,
  required int? seconds,
  required String title,
}) async {
  final repsController = TextEditingController(text: reps?.toString() ?? '');
  final weightController = TextEditingController(
    text: weightKg == null
        ? ''
        : (weightKg == weightKg.roundToDouble()
            ? weightKg.toStringAsFixed(0)
            : weightKg.toStringAsFixed(1)),
  );
  final secondsController = TextEditingController(
    text: seconds?.toString() ?? '',
  );
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: kind == exerciseKindTime
            ? [
                TextField(
                  controller: secondsController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: context.l10n.historySeconds,
                    suffixText: 's',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: weightController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: context.l10n.historyWeightOptional,
                    suffixText: 'kg',
                  ),
                ),
              ]
            : [
                TextField(
                  controller: weightController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: context.l10n.historyWeight,
                    suffixText: 'kg',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: repsController,
                  keyboardType: TextInputType.number,
                  decoration:
                      InputDecoration(labelText: context.l10n.historyReps),
                ),
              ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l10n.historyCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(ctx.l10n.historySave),
        ),
      ],
    ),
  );
  if (result != true) return null;
  if (kind == exerciseKindTime) {
    final s = int.tryParse(secondsController.text.trim());
    if (s == null) return null;
    final w = double.tryParse(weightController.text.trim());
    return (null, w, s);
  }
  final r = int.tryParse(repsController.text.trim());
  final w = double.tryParse(weightController.text.trim());
  if (r == null || w == null) return null;
  return (r, w, null);
}

class _ImprovementsBanner extends ConsumerStatefulWidget {
  const _ImprovementsBanner({required this.workoutId, required this.version});

  final String workoutId;

  /// The workout's version. Editing the workout bumps it, which is the signal
  /// to recompute — otherwise the banner keeps showing improvements found when
  /// the page opened, naming exercises the user has since removed or swapped.
  final int version;

  @override
  ConsumerState<_ImprovementsBanner> createState() =>
      _ImprovementsBannerState();
}

class _ImprovementsBannerState extends ConsumerState<_ImprovementsBanner> {
  /// Dismissal is persisted, not widget state: this widget is rebuilt whenever
  /// the workout stream ticks and recreated whenever the page is reopened, so
  /// an in-memory flag made "Dismiss" look like it did nothing.
  static String _dismissKey(String workoutId) =>
      'improvements_dismissed_$workoutId';

  Future<List<WorkoutImprovement>>? _future;

  /// null while the persisted flag is still loading — render nothing rather
  /// than flashing a banner the user already dismissed.
  bool? _dismissed;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadDismissed();
  }

  @override
  void didUpdateWidget(_ImprovementsBanner old) {
    super.didUpdateWidget(old);
    if (old.workoutId != widget.workoutId) {
      _dismissed = null;
      _loadDismissed();
      setState(_reload);
    } else if (old.version != widget.version) {
      setState(_reload);
    }
  }

  Future<void> _loadDismissed() async {
    bool value = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      value = prefs.getBool(_dismissKey(widget.workoutId)) ?? false;
    } catch (e, st) {
      // Prefs can be unavailable on some web builds; showing the banner is the
      // safe failure (the user can dismiss again) — never block the page.
      debugPrint('improvements dismissal read failed: $e\n$st');
    }
    if (!mounted) return;
    setState(() => _dismissed = value);
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_dismissKey(widget.workoutId), true);
    } catch (e, st) {
      debugPrint('improvements dismissal write failed: $e\n$st');
    }
  }

  void _reload() {
    _future = ref
        .read(workoutRepositoryProvider)
        .findWorkoutImprovements(widget.workoutId);
  }

  Future<void> _apply() async {
    await ref
        .read(workoutRepositoryProvider)
        .applyWorkoutImprovements(widget.workoutId);
    if (!mounted) return;
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed != false) return const SizedBox.shrink();
    return FutureBuilder<List<WorkoutImprovement>>(
      future: _future,
      builder: (context, snap) {
        final list = snap.data;
        if (list == null || list.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final preview = list.take(3).toList();
        final extra = list.length - preview.length;
        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          color: theme.colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.historyImprovementsHeadline(list.length),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 6),
                for (final imp in preview)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      _formatImprovement(context, imp),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                if (extra > 0)
                  Text(
                    context.l10n.historyAndMore(extra),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _dismiss,
                      child: Text(context.l10n.historyDismiss),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: _apply,
                      child: Text(context.l10n.historyApply),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _formatImprovement(BuildContext context, WorkoutImprovement imp) {
    final l10n = context.l10n;
    if (imp.kind == exerciseKindTime) {
      return l10n.historyImprovementTime(
        imp.exerciseName,
        imp.setIndex + 1,
        '${imp.oldSeconds}',
        '${imp.newSeconds}',
      );
    }
    return l10n.historyImprovementReps(
      imp.exerciseName,
      imp.setIndex + 1,
      '${imp.oldReps}',
      _fmtWeight(context, imp.oldWeightKg),
      '${imp.newReps}',
      _fmtWeight(context, imp.newWeightKg),
    );
  }

  static String _fmtWeight(BuildContext context, double? w) =>
      w == null ? '—' : _weightText(context, w);
}

String _weightText(BuildContext context, double w) => NumberFormat(
      w == w.roundToDouble() ? '0' : '0.0',
      Localizations.localeOf(context).toString(),
    ).format(w);
