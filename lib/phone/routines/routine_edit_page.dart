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
      final r = await db.createRoutine('New routine');
      _routineId = r.id;
      _nameController.text = r.name;
    } else {
      final full = await db.loadFullRoutine(_routineId!);
      _nameController.text = full?.routine.name ?? '';
    }
    if (!mounted) return;
    setState(() => _initializing = false);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _routineId == null) return;
    await ref.read(databaseProvider).renameRoutine(_routineId!, name);
  }

  Future<void> _delete() async {
    if (_routineId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete routine?'),
        content: Text(
          'Delete "${_nameController.text}" and all of its planned sets?',
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
    final db = ref.read(databaseProvider);
    final exercises = await db.watchExercises().first;
    if (!mounted) return;
    final picked = await showModalBottomSheet<Exercise>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        if (exercises.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'No exercises yet',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                const Text('Create one in the Exercises tab first.'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: exercises.length,
            itemBuilder: (context, i) {
              final e = exercises[i];
              return ListTile(
                title: Text(e.name),
                onTap: () => Navigator.of(ctx).pop(e),
              );
            },
          ),
        );
      },
    );
    if (picked == null) return;
    await db.addExerciseToRoutine(
      routineId: _routineId!,
      exerciseId: picked.id,
    );
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

  @override
  Widget build(BuildContext context) {
    if (_initializing || _routineId == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final fullAsync = ref.watch(fullRoutineProvider(_routineId!));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit routine'),
        actions: [
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
          if (full == null) {
            return const Center(child: Text('Routine not found'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                onEditingComplete: _saveName,
                onTapOutside: (_) => _saveName(),
              ),
              const SizedBox(height: 24),
              if (full.exercises.isEmpty)
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
              for (final re in full.exercises) ...[
                _ExerciseCard(
                  fullExercise: re,
                  onRest: () => _editRest(re.routineExercise),
                ),
                const SizedBox(height: 16),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({required this.fullExercise, required this.onRest});

  final FullRoutineExercise fullExercise;
  final VoidCallback onRest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fullExercise.exercise.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: onRest,
                  icon: const Icon(Icons.timer_outlined, size: 18),
                  label: Text(
                    '${fullExercise.routineExercise.restSeconds}s rest',
                  ),
                ),
                IconButton(
                  onPressed: () =>
                      db.removeRoutineExercise(fullExercise.routineExercise.id),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove from routine',
                ),
              ],
            ),
            const Divider(),
            for (var i = 0; i < fullExercise.plannedSets.length; i++)
              PlannedSetRow(
                key: ValueKey(fullExercise.plannedSets[i].id),
                setIndex: i,
                plannedSet: fullExercise.plannedSets[i],
                onChanged: (reps, weight) => db.updatePlannedSet(
                  id: fullExercise.plannedSets[i].id,
                  targetReps: reps,
                  targetWeightKg: weight,
                ),
                onDelete: () =>
                    db.deletePlannedSet(fullExercise.plannedSets[i].id),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final last = fullExercise.plannedSets.lastOrNull;
                  db.addPlannedSet(
                    routineExerciseId: fullExercise.routineExercise.id,
                    targetReps: last?.targetReps ?? 10,
                    targetWeightKg: last?.targetWeightKg ?? 20,
                  );
                },
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
