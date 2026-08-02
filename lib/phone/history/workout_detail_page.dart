import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../routines/exercise_picker.dart';

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
        title: const Text('Workout'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete workout',
            onPressed: () => _deleteWorkout(context),
          ),
        ],
      ),
      body: asyncSnap.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (snap) {
          if (snap == null) {
            return const Center(child: Text('Workout not found'));
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
        title: const Text('Delete workout?'),
        content: const Text('This removes the workout and its completions.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
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

class _Body extends ConsumerWidget {
  const _Body({required this.snap});

  final FullWorkout snap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(workoutRepositoryProvider);
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
                title: const Text('Started'),
                subtitle: _StampRow(
                  value: snap.workout.startedAt,
                  onEditDate: () => _editStamp(context, ref, isStart: true, date: true),
                  onEditTime: () => _editStamp(context, ref, isStart: true, date: false),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.stop_outlined),
                title: const Text('Ended'),
                subtitle: snap.workout.endedAt == null
                    // No timestamp to split yet, so offer the full flow.
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () =>
                              _editStamp(context, ref, isStart: false, date: true, thenTime: true),
                          child: const Text('In progress — set end'),
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
                  title: const Text('Routine'),
                  subtitle: Text(snap.routine!.name),
                ),
              if (snap.workout.avgHeartRate != null ||
                  snap.workout.maxHeartRate != null) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.favorite, color: Colors.redAccent),
                  title: const Text('Heart rate'),
                  subtitle: Text(
                    _hrLine(
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
        for (final ex in snap.exercises) ...[
          _ExerciseSection(
            ex: ex,
            onAddSet: () => _addSet(context, ref, ex),
            onRemoveExercise: () => _removeExercise(context, ref, ex),
            onEditCompletion: (set) =>
                _editCompletion(context, ref, ex: ex, set: set),
            onRemoveCompletion: (id) => db.deleteCompletion(id),
            onRemoveSet: (id) => db.removeWorkoutSet(id),
          ),
          const SizedBox(height: 12),
        ],
        Center(
          child: TextButton.icon(
            onPressed: () => _addExercise(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('Add exercise'),
          ),
        ),
      ],
    );
  }

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
      title: finished ? 'Add completed set' : 'Add set',
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
        title: const Text('Remove exercise?'),
        content: Text(
          'Remove "${ex.workoutExercise.exerciseName}" from this workout?',
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
      title: c == null ? 'Add completion' : 'Edit completion',
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

  Future<void> _addExercise(BuildContext context, WidgetRef ref) async {
    final workouts = ref.read(workoutRepositoryProvider);
    // The routine editor's picker — name search, muscle filters, and a "Create
    // new exercise" tile. The workout editor used to roll its own list, which
    // is why an exercise could not be created while adding one here. No
    // excludeIds: repeating an exercise within a workout is legitimate.
    final picked = await showExercisePicker(context, ref);
    if (picked == null) return;
    await workouts.addWorkoutExercise(
      workoutId: snap.workout.syncId,
      exerciseId: picked.syncId,
    );
  }

  static String _hrLine(int? avg, int? max) {
    if (avg != null && max != null) return 'avg $avg · max $max bpm';
    if (avg != null) return 'avg $avg bpm';
    return 'max $max bpm';
  }
}

class _ExerciseSection extends ConsumerWidget {
  const _ExerciseSection({
    required this.ex,
    required this.onAddSet,
    required this.onRemoveExercise,
    required this.onEditCompletion,
    required this.onRemoveCompletion,
    required this.onRemoveSet,
  });

  final FullWorkoutExercise ex;
  final VoidCallback onAddSet;
  final VoidCallback onRemoveExercise;
  final void Function(FullWorkoutSet set) onEditCompletion;
  final void Function(String completionId) onRemoveCompletion;
  final void Function(String workoutSetId) onRemoveSet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final exerciseId = ex.workoutExercise.exerciseId;
    return Card(
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
                  onPressed: onRemoveExercise,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove exercise',
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
                label: const Text('Add set'),
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
    String descActual;
    String descTarget;
    if (kind == exerciseKindTime) {
      if (completion?.actualSeconds == null) {
        descActual = '—';
      } else {
        final s = completion!.actualSeconds!;
        final w = completion.actualWeightKg;
        descActual = w == null || w == 0
            ? '$s s'
            : '$s s @ ${w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1)} kg';
      }
      final ts = set.workoutSet.targetSeconds;
      final tw = set.workoutSet.targetWeightKg;
      if (ts == null) {
        descTarget = '';
      } else if (tw == null || tw == 0) {
        descTarget = 'target ${ts}s';
      } else {
        descTarget =
            'target ${ts}s @ ${tw == tw.roundToDouble() ? tw.toStringAsFixed(0) : tw.toStringAsFixed(1)} kg';
      }
    } else {
      if (completion == null) {
        descActual = '—';
      } else {
        final w = completion.actualWeightKg ?? 0;
        final wStr = w == w.roundToDouble()
            ? w.toStringAsFixed(0)
            : w.toStringAsFixed(1);
        descActual = '$wStr kg × ${completion.actualReps ?? 0}';
      }
      final tw = set.workoutSet.targetWeightKg;
      final tr = set.workoutSet.targetReps;
      descTarget = (tw == null || tr == null)
          ? ''
          : 'target ${tw == tw.roundToDouble() ? tw.toStringAsFixed(0) : tw.toStringAsFixed(1)} kg × $tr';
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
                tooltip: 'Remove completion',
              ),
            IconButton(
              onPressed: onRemoveSet,
              icon: const Icon(Icons.close),
              tooltip: 'Remove set',
            ),
          ],
        ),
      ),
    );
  }
}

String _setHrLine(int? avg, int? max) {
  if (avg != null && max != null) return 'HR avg $avg · max $max';
  if (avg != null) return 'HR avg $avg';
  return 'HR max $max';
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
    final d = value;
    final dateLabel =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final timeLabel =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 4,
        children: [
          _StampChip(
            icon: Icons.event_outlined,
            label: dateLabel,
            tooltip: 'Change date',
            onTap: onEditDate,
          ),
          _StampChip(
            icon: Icons.schedule_outlined,
            label: timeLabel,
            tooltip: 'Change time',
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
  String title = 'Set',
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
                  decoration: const InputDecoration(
                    labelText: 'Seconds',
                    suffixText: 's',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: weightController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Weight (optional)',
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
                  decoration: const InputDecoration(
                    labelText: 'Weight',
                    suffixText: 'kg',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: repsController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Reps'),
                ),
              ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Save'),
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
                  '${list.length} set${list.length == 1 ? '' : 's'} exceeded their target',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 6),
                for (final imp in preview)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      _formatImprovement(imp),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                if (extra > 0)
                  Text(
                    '…and $extra more',
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
                      child: const Text('Dismiss'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: _apply,
                      child: const Text('Apply'),
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

  static String _formatImprovement(WorkoutImprovement imp) {
    final setLabel = 'set ${imp.setIndex + 1}';
    if (imp.kind == exerciseKindTime) {
      return '${imp.exerciseName} · $setLabel · ${imp.oldSeconds}s → ${imp.newSeconds}s';
    }
    final oldW = _fmtWeight(imp.oldWeightKg);
    final newW = _fmtWeight(imp.newWeightKg);
    return '${imp.exerciseName} · $setLabel · ${imp.oldReps}×$oldW → ${imp.newReps}×$newW';
  }

  static String _fmtWeight(double? w) {
    if (w == null) return '—';
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }
}
