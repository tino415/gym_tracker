import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';

class WorkoutDetailPage extends ConsumerStatefulWidget {
  const WorkoutDetailPage({super.key, required this.workoutId});

  final int workoutId;

  @override
  ConsumerState<WorkoutDetailPage> createState() => _WorkoutDetailPageState();
}

class _WorkoutDetailPageState extends ConsumerState<WorkoutDetailPage> {
  @override
  Widget build(BuildContext context) {
    final asyncSnap = ref.watch(fullWorkoutProvider(widget.workoutId));
    return Scaffold(
      appBar: AppBar(
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
    await ref.read(databaseProvider).deleteWorkout(widget.workoutId);
    if (!mounted) return;
    router.pop();
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.snap});

  final FullWorkout snap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: const Text('Started'),
                subtitle: Text(_fmt(snap.workout.startedAt)),
                onTap: () => _editTime(context, ref, isStart: true),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.stop_outlined),
                title: const Text('Ended'),
                subtitle: Text(
                  snap.workout.endedAt == null
                      ? 'In progress'
                      : _fmt(snap.workout.endedAt!),
                ),
                onTap: () => _editTime(context, ref, isStart: false),
              ),
              if (snap.routine != null)
                ListTile(
                  leading: const Icon(Icons.fitness_center),
                  title: const Text('Routine'),
                  subtitle: Text(snap.routine!.name),
                ),
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

  Future<void> _editTime(
    BuildContext context,
    WidgetRef ref, {
    required bool isStart,
  }) async {
    final initial = isStart ? snap.workout.startedAt : snap.workout.endedAt;
    final base = initial ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return;
    final merged = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final db = ref.read(databaseProvider);
    await db.updateWorkoutTimes(
      workoutId: snap.workout.id,
      startedAt: isStart ? merged : snap.workout.startedAt,
      endedAt: isStart ? snap.workout.endedAt : merged,
    );
  }

  Future<void> _addSet(
    BuildContext context,
    WidgetRef ref,
    FullWorkoutExercise ex,
  ) async {
    final values = await _showSetEditDialog(
      context,
      kind: ex.kind,
      reps: null,
      weightKg: null,
      seconds: null,
    );
    if (values == null) return;
    await ref.read(databaseProvider).addWorkoutSet(
          workoutExerciseId: ex.workoutExercise.id,
          targetReps: values.$1,
          targetWeightKg: values.$2,
          targetSeconds: values.$3,
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
    await ref.read(databaseProvider).removeWorkoutExercise(ex.workoutExercise.id);
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
    final db = ref.read(databaseProvider);
    if (c == null) {
      await db.upsertSetCompletion(
        workoutId: snap.workout.id,
        workoutSetId: set.workoutSet.id,
        actualReps: values.$1,
        actualWeightKg: values.$2,
        actualSeconds: values.$3,
      );
    } else {
      await db.updateCompletion(
        id: c.id,
        actualReps: values.$1,
        actualWeightKg: values.$2,
        actualSeconds: values.$3,
      );
    }
  }

  Future<void> _addExercise(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    final exercises = await db.watchExercises().first;
    if (!context.mounted) return;
    final picked = await showModalBottomSheet<Exercise>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final e in exercises)
              ListTile(
                leading: Icon(
                  e.kind == exerciseKindTime
                      ? Icons.timer_outlined
                      : Icons.repeat,
                ),
                title: Text(e.name),
                onTap: () => Navigator.of(ctx).pop(e),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await db.addWorkoutExercise(
      workoutId: snap.workout.id,
      exerciseId: picked.id,
    );
  }

  static String _fmt(DateTime dt) {
    final y = dt.year;
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$y-$mo-$d $h:$mi';
  }
}

class _ExerciseSection extends StatelessWidget {
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
  final void Function(int completionId) onRemoveCompletion;
  final void Function(int workoutSetId) onRemoveSet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            const Divider(),
            for (var i = 0; i < ex.sets.length; i++)
              _SetRow(
                index: i,
                set: ex.sets[i],
                kind: ex.kind,
                onEdit: () => onEditCompletion(ex.sets[i]),
                onRemoveCompletion: ex.sets[i].completion == null
                    ? null
                    : () => onRemoveCompletion(ex.sets[i].completion!.id),
                onRemoveSet: () => onRemoveSet(ex.sets[i].workoutSet.id),
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

/// Returns (reps, weightKg, seconds) — at most two of them are non-null,
/// depending on [kind]. Null overall means the user cancelled.
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
