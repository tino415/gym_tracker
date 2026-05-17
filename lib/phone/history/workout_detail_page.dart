import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/providers.dart';

class WorkoutDetailPage extends ConsumerStatefulWidget {
  const WorkoutDetailPage({super.key, required this.workoutId});

  final int workoutId;

  @override
  ConsumerState<WorkoutDetailPage> createState() => _WorkoutDetailPageState();
}

class _WorkoutDetailPageState extends ConsumerState<WorkoutDetailPage> {
  Workout? _workout;
  List<SetCompletion> _completions = const [];
  final _exerciseNameCache = <int, String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final workouts = await db.watchRecentWorkouts().first;
    final workout = workouts.where((w) => w.id == widget.workoutId).firstOrNull;
    final completions = await db.completionsForWorkout(widget.workoutId);
    for (final c in completions) {
      if (_exerciseNameCache.containsKey(c.plannedSetId)) continue;
      final ps = await (db.select(
        db.plannedSets,
      )..where((t) => t.id.equals(c.plannedSetId))).getSingleOrNull();
      if (ps == null) continue;
      final re = await (db.select(
        db.routineExercises,
      )..where((t) => t.id.equals(ps.routineExerciseId))).getSingleOrNull();
      if (re == null) continue;
      final ex = await (db.select(
        db.exercises,
      )..where((t) => t.id.equals(re.exerciseId))).getSingleOrNull();
      if (ex == null) continue;
      _exerciseNameCache[c.plannedSetId] = ex.name;
    }
    if (!mounted) return;
    setState(() {
      _workout = workout;
      _completions = completions;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Workout')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_workout == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Workout')),
        body: const Center(child: Text('Workout not found')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Workout')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Started: ${_workout!.startedAt}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (_workout!.endedAt != null)
            Text(
              'Ended: ${_workout!.endedAt}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          const SizedBox(height: 16),
          if (_completions.isEmpty)
            const Text('No sets recorded.')
          else
            for (final c in _completions)
              ListTile(
                dense: true,
                title: Text(
                  _exerciseNameCache[c.plannedSetId] ?? 'Unknown exercise',
                ),
                subtitle: Text('${c.actualWeightKg} kg × ${c.actualReps}'),
              ),
        ],
      ),
    );
  }
}
