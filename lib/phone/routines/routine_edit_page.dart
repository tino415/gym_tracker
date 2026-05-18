import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import 'planned_set_row.dart';

class RoutineEditPage extends ConsumerStatefulWidget {
  const RoutineEditPage({super.key, this.routineId});

  final int? routineId;

  @override
  ConsumerState<RoutineEditPage> createState() => _RoutineEditPageState();
}

class _RoutineEditPageState extends ConsumerState<RoutineEditPage> {
  final _nameController = TextEditingController();
  String _initialName = '';
  int? _routineId;
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _routineId = widget.routineId;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final db = ref.read(databaseProvider);
    if (_routineId == null) {
      // Defer creation until the user explicitly saves a name or adds an
      // exercise. The list page no longer shows half-baked "New routine"
      // entries that appeared just because the editor was opened.
      _initialName = '';
      _nameController.text = '';
    } else {
      final full = await db.loadFullRoutine(_routineId!);
      _initialName = full?.routine.name ?? '';
      _nameController.text = _initialName;
    }
    if (!mounted) return;
    setState(() => _initializing = false);
  }

  /// Persist the routine if we're still in draft state. Returns the routine
  /// id (creating one if needed). Empty names short-circuit with null.
  Future<int?> _ensurePersisted() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return null;
    if (_routineId != null) {
      if (_nameDirty) {
        await ref.read(databaseProvider).renameRoutine(_routineId!, name);
        _initialName = name;
      }
      return _routineId;
    }
    final created = await ref.read(databaseProvider).createRoutine(name);
    _initialName = name;
    setState(() => _routineId = created.id);
    return created.id;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _nameDirty => _nameController.text.trim() != _initialName.trim();

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty && (_routineId == null || _nameDirty);

  Future<void> _saveName() async {
    await _ensurePersisted();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _delete() async {
    if (_routineId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete routine?'),
        content: Text(
          'Delete "${_nameController.text}"? Past workouts will keep their own copy and remain in History.',
        ),
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
    await ref.read(databaseProvider).deleteRoutine(_routineId!);
    if (!mounted) return;
    context.pop();
  }

  Future<void> _pickExerciseToAdd() async {
    final routineId = await _ensurePersisted();
    if (routineId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the routine a name first')),
      );
      return;
    }
    final db = ref.read(databaseProvider);
    if (!mounted) return;
    final picked = await _showExercisePicker(context);
    if (picked == null || _routineId == null) return;
    await db.addExerciseToRoutine(
      routineId: _routineId!,
      exerciseId: picked.id,
    );
  }

  /// Shared bottom-sheet exercise picker. Used both for adding an exercise to
  /// the routine and for adding an alternative — [excludeIds] hides anything
  /// already in the slot to avoid duplicates.
  Future<Exercise?> _showExercisePicker(
    BuildContext context, {
    Set<int> excludeIds = const {},
  }) async {
    final db = ref.read(databaseProvider);
    final all = await db.watchExercises().first;
    final exercises = excludeIds.isEmpty
        ? all
        : all.where((e) => !excludeIds.contains(e.id)).toList();
    if (!context.mounted) return null;
    return showModalBottomSheet<Exercise>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Create new exercise'),
                onTap: () async {
                  final created = await _showCreateExerciseDialog(ctx);
                  if (created != null && ctx.mounted) {
                    Navigator.of(ctx).pop(created);
                  }
                },
              ),
              const Divider(height: 1),
              if (exercises.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No exercises available.',
                    textAlign: TextAlign.center,
                  ),
                )
              else
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
        );
      },
    );
  }

  Future<void> _addAlternative(FullRoutineExercise re) async {
    final excludeIds = <int>{
      re.exercise.id,
      ...re.alternatives.map((a) => a.exercise.id),
    };
    final picked = await _showExercisePicker(context, excludeIds: excludeIds);
    if (picked == null) return;
    await ref.read(databaseProvider).addRoutineExerciseAlternative(
          routineExerciseId: re.routineExercise.id,
          exerciseId: picked.id,
        );
  }

  Future<Exercise?> _showCreateExerciseDialog(BuildContext context) async {
    final controller = TextEditingController();
    String kind = exerciseKindReps;
    final result = await showDialog<Exercise>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New exercise'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: exerciseKindReps, label: Text('Reps')),
                  ButtonSegment(value: exerciseKindTime, label: Text('Time')),
                ],
                selected: {kind},
                onSelectionChanged: (s) => setLocal(() => kind = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                try {
                  final db = ref.read(databaseProvider);
                  final created = await db.createExercise(name, kind: kind);
                  if (!ctx.mounted) return;
                  Navigator.of(ctx).pop(created);
                } catch (e) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('Could not create: $e')),
                  );
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _editRest(RoutineExercise re) async {
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
    if (result != null && result > 0) {
      await ref.read(databaseProvider).setRestSeconds(re.id, result);
    }
  }

  Future<void> _toggleSuperset(
    FullRoutine full,
    FullRoutineExercise current,
    int idx,
  ) async {
    if (idx == 0) return; // first card has nothing to group with
    final db = ref.read(databaseProvider);
    final prev = full.exercises[idx - 1];
    final currentGroup = current.routineExercise.supersetGroup;
    if (currentGroup != null && currentGroup == prev.routineExercise.supersetGroup) {
      // Already grouped with previous — ungroup this one.
      await db.setSupersetGroup(current.routineExercise.id, null);
      return;
    }
    // Group with previous: reuse prev's group if any, otherwise allocate a
    // new one (max existing group on this routine + 1).
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
      await db.setSupersetGroup(prev.routineExercise.id, group);
    }
    await db.setSupersetGroup(current.routineExercise.id, group);
  }

  Future<void> _editSetDialog({
    required FullRoutineExercise re,
    PlannedSet? existing,
  }) async {
    final isTime = re.kind == exerciseKindTime;
    final repsController = TextEditingController(
      text: existing?.targetReps?.toString() ?? '10',
    );
    final weightController = TextEditingController(
      text: existing?.targetWeightKg?.toStringAsFixed(0) ?? '20',
    );
    final secondsController = TextEditingController(
      text: existing?.targetSeconds?.toString() ?? '30',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New set' : 'Edit set'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: isTime
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
    if (saved != true) return;
    final db = ref.read(databaseProvider);
    if (isTime) {
      final seconds = int.tryParse(secondsController.text.trim());
      if (seconds == null || seconds <= 0) return;
      final weight = double.tryParse(weightController.text.trim());
      if (existing == null) {
        await db.addPlannedSet(
          routineExerciseId: re.routineExercise.id,
          targetSeconds: seconds,
          targetWeightKg: weight,
        );
      } else {
        await db.updatePlannedSet(
          id: existing.id,
          targetSeconds: seconds,
          targetWeightKg: weight,
        );
      }
    } else {
      final reps = int.tryParse(repsController.text.trim());
      final weight = double.tryParse(weightController.text.trim());
      if (reps == null || weight == null) return;
      if (existing == null) {
        await db.addPlannedSet(
          routineExerciseId: re.routineExercise.id,
          targetReps: reps,
          targetWeightKg: weight,
        );
      } else {
        await db.updatePlannedSet(
          id: existing.id,
          targetReps: reps,
          targetWeightKg: weight,
        );
      }
    }
  }

  Future<void> _editAltSetDialog({
    required RoutineAlternative alt,
    AlternativePlannedSet? existing,
  }) async {
    final isTime = alt.exercise.kind == exerciseKindTime;
    final repsController = TextEditingController(
      text: existing?.targetReps?.toString() ?? '10',
    );
    final weightController = TextEditingController(
      text: existing?.targetWeightKg?.toStringAsFixed(0) ?? '20',
    );
    final secondsController = TextEditingController(
      text: existing?.targetSeconds?.toString() ?? '30',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New set' : 'Edit set'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: isTime
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
    if (saved != true) return;
    final db = ref.read(databaseProvider);
    if (isTime) {
      final seconds = int.tryParse(secondsController.text.trim());
      if (seconds == null || seconds <= 0) return;
      final weight = double.tryParse(weightController.text.trim());
      if (existing == null) {
        await db.addAlternativePlannedSet(
          alternativeId: alt.join.id,
          targetSeconds: seconds,
          targetWeightKg: weight,
        );
      } else {
        await db.updateAlternativePlannedSet(
          id: existing.id,
          targetSeconds: seconds,
          targetWeightKg: weight,
        );
      }
    } else {
      final reps = int.tryParse(repsController.text.trim());
      final weight = double.tryParse(weightController.text.trim());
      if (reps == null || weight == null) return;
      if (existing == null) {
        await db.addAlternativePlannedSet(
          alternativeId: alt.join.id,
          targetReps: reps,
          targetWeightKg: weight,
        );
      } else {
        await db.updateAlternativePlannedSet(
          id: existing.id,
          targetReps: reps,
          targetWeightKg: weight,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final isDraft = _routineId == null;
    final fullAsync = isDraft
        ? const AsyncValue<FullRoutine?>.data(null)
        : ref.watch(fullRoutineProvider(_routineId!));
    return Scaffold(
      appBar: AppBar(
        title: Text(isDraft ? 'New routine' : 'Edit routine'),
        actions: [
          IconButton(
            onPressed: _canSave ? _saveName : null,
            icon: const Icon(Icons.check),
            tooltip: 'Save',
          ),
          if (!isDraft)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete routine',
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickExerciseToAdd,
        icon: const Icon(Icons.add),
        label: const Text('Add exercise'),
      ),
      body: fullAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (full) {
          final exercises = full?.exercises ?? const <FullRoutineExercise>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            children: [
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Name',
                  border: const OutlineInputBorder(),
                  helperText: isDraft
                      ? 'Tap ✓ to save and start adding exercises'
                      : 'Tap ✓ to save changes',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              if (isDraft)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'Save the routine first to add exercises.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                )
              else if (exercises.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text(
                      'No exercises in this routine yet.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              if (!isDraft)
                for (var i = 0; i < exercises.length; i++) ...[
                  _ExerciseCard(
                    fullExercise: exercises[i],
                    isFirst: i == 0,
                    groupedWithPrev: i > 0 &&
                        exercises[i].routineExercise.supersetGroup != null &&
                        exercises[i].routineExercise.supersetGroup ==
                            exercises[i - 1].routineExercise.supersetGroup,
                    onRest: () => _editRest(exercises[i].routineExercise),
                    onToggleSuperset: () =>
                        _toggleSuperset(full!, exercises[i], i),
                    onEditSet: (s) =>
                        _editSetDialog(re: exercises[i], existing: s),
                    onAddSet: () => _editSetDialog(re: exercises[i]),
                    onAddAlternative: () => _addAlternative(exercises[i]),
                    onAddAlternativeSet: (alt) => _editAltSetDialog(alt: alt),
                    onEditAlternativeSet: (alt, existing) =>
                        _editAltSetDialog(alt: alt, existing: existing),
                  ),
                  const SizedBox(height: 12),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({
    required this.fullExercise,
    required this.isFirst,
    required this.groupedWithPrev,
    required this.onRest,
    required this.onToggleSuperset,
    required this.onEditSet,
    required this.onAddSet,
    required this.onAddAlternative,
    required this.onAddAlternativeSet,
    required this.onEditAlternativeSet,
  });

  final FullRoutineExercise fullExercise;
  final bool isFirst;
  final bool groupedWithPrev;
  final VoidCallback onRest;
  final VoidCallback onToggleSuperset;
  final void Function(PlannedSet) onEditSet;
  final VoidCallback onAddSet;
  final VoidCallback onAddAlternative;
  final void Function(RoutineAlternative alt) onAddAlternativeSet;
  final void Function(RoutineAlternative alt, AlternativePlannedSet set)
      onEditAlternativeSet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final theme = Theme.of(context);
    final supersetColor = theme.colorScheme.primary;
    return Card(
      shape: groupedWithPrev
          ? RoundedRectangleBorder(
              side: BorderSide(color: supersetColor, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        fullExercise.kind == exerciseKindTime
                            ? Icons.timer_outlined
                            : Icons.repeat,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          fullExercise.exercise.name,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: onRest,
                  icon: const Icon(Icons.timer_outlined, size: 18),
                  label: Text('${fullExercise.routineExercise.restSeconds}s'),
                ),
                IconButton(
                  onPressed: () =>
                      db.removeRoutineExercise(fullExercise.routineExercise.id),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove from routine',
                ),
              ],
            ),
            if (!isFirst)
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  selected: groupedWithPrev,
                  onSelected: (_) => onToggleSuperset(),
                  label: const Text('Superset with previous'),
                  avatar: Icon(
                    groupedWithPrev ? Icons.link : Icons.link_off,
                    size: 16,
                  ),
                ),
              ),
            const Divider(),
            for (var i = 0; i < fullExercise.plannedSets.length; i++)
              PlannedSetRow(
                key: ValueKey(fullExercise.plannedSets[i].id),
                setIndex: i,
                plannedSet: fullExercise.plannedSets[i],
                kind: fullExercise.kind,
                onEdit: () => onEditSet(fullExercise.plannedSets[i]),
                onDelete: () =>
                    db.deletePlannedSet(fullExercise.plannedSets[i].id),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAddSet,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add set'),
              ),
            ),
            const Divider(),
            _AlternativesSection(
              fullExercise: fullExercise,
              onAdd: onAddAlternative,
              onAddAltSet: onAddAlternativeSet,
              onEditAltSet: onEditAlternativeSet,
            ),
          ],
        ),
      ),
    );
  }
}

class _AlternativesSection extends ConsumerWidget {
  const _AlternativesSection({
    required this.fullExercise,
    required this.onAdd,
    required this.onAddAltSet,
    required this.onEditAltSet,
  });

  final FullRoutineExercise fullExercise;
  final VoidCallback onAdd;
  final void Function(RoutineAlternative alt) onAddAltSet;
  final void Function(RoutineAlternative alt, AlternativePlannedSet set)
      onEditAltSet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(databaseProvider);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.swap_horiz, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text(
              'Alternatives',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        if (fullExercise.alternatives.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Swap targets at workout time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else
          for (final alt in fullExercise.alternatives)
            _AlternativeTile(
              parentKind: fullExercise.kind,
              alternative: alt,
              onDelete: () => db.removeRoutineExerciseAlternative(alt.join.id),
              onAddSet: () => onAddAltSet(alt),
              onEditSet: (s) => onEditAltSet(alt, s),
              onDeleteSet: (s) => db.deleteAlternativePlannedSet(s.id),
            ),
      ],
    );
  }
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
      // ExpansionTile draws its own internal divider; suppress the outer
      // ListTile divider that Material 3 adds by default.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(
          ex.kind == exerciseKindTime
              ? Icons.timer_outlined
              : Icons.repeat,
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
