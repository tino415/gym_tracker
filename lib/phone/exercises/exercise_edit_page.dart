import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';

class ExerciseEditPage extends ConsumerStatefulWidget {
  const ExerciseEditPage({super.key, this.exerciseId});

  final int? exerciseId;

  @override
  ConsumerState<ExerciseEditPage> createState() => _ExerciseEditPageState();
}

class _ExerciseEditPageState extends ConsumerState<ExerciseEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  String _kind = exerciseKindReps;
  Exercise? _loaded;
  bool _initializing = true;
  // Muscle ids currently selected for the exercise being edited. Resolved from
  // the join table on load; replaced wholesale on save.
  final Set<int> _selectedMuscleIds = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.exerciseId == null) {
      setState(() => _initializing = false);
      return;
    }
    final db = ref.read(exerciseRepositoryProvider);
    final list = await db.watchExercises().first;
    final found = list.where((e) => e.id == widget.exerciseId).firstOrNull;
    final mus = found == null
        ? const <Muscle>[]
        : await db.musclesForExercise(found.id);
    setState(() {
      _loaded = found;
      _nameController.text = found?.name ?? '';
      _kind = found?.kind ?? exerciseKindReps;
      _selectedMuscleIds
        ..clear()
        ..addAll(mus.map((m) => m.id));
      _initializing = false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final db = ref.read(exerciseRepositoryProvider);
    final name = _nameController.text.trim();
    try {
      final Exercise exercise;
      if (_loaded == null) {
        exercise = await db.createExercise(name, kind: _kind);
      } else {
        await db.renameExercise(_loaded!.id, name);
        if (_loaded!.kind != _kind) {
          await db.setExerciseKind(_loaded!.id, _kind);
        }
        exercise = _loaded!;
      }
      await db.setExerciseMuscles(exercise.id, _selectedMuscleIds.toList());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      return;
    }
    if (!mounted) return;
    context.pop();
  }

  Future<void> _delete() async {
    if (_loaded == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete exercise?'),
        content: Text(
          'Delete "${_loaded!.name}"? Workouts that reference it will need to be edited.',
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
    try {
      await ref.read(exerciseRepositoryProvider).deleteExercise(_loaded!.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      return;
    }
    if (!mounted) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final isEdit = _loaded != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit exercise' : 'New exercise'),
        actions: [
          if (isEdit)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _save(),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Name is required';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: exerciseKindReps,
                    label: Text('Reps'),
                    icon: Icon(Icons.repeat),
                  ),
                  ButtonSegment(
                    value: exerciseKindTime,
                    label: Text('Time'),
                    icon: Icon(Icons.timer_outlined),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 16),
              _MuscleSelector(
                selectedIds: _selectedMuscleIds,
                onToggled: (id) => setState(() {
                  if (!_selectedMuscleIds.add(id)) {
                    _selectedMuscleIds.remove(id);
                  }
                }),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MuscleSelector extends ConsumerWidget {
  const _MuscleSelector({required this.selectedIds, required this.onToggled});

  final Set<int> selectedIds;
  final ValueChanged<int> onToggled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final musclesAsync = ref.watch(musclesStreamProvider);
    return musclesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text('Could not load muscles: $e'),
      data: (muscles) {
        if (muscles.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Muscles', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final m in muscles)
                  FilterChip(
                    label: Text(m.name),
                    selected: selectedIds.contains(m.id),
                    onSelected: (_) => onToggled(m.id),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
