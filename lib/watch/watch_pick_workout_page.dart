import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import 'watch_run_page.dart';

class WatchPickWorkoutPage extends ConsumerWidget {
  const WatchPickWorkoutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workoutsAsync = ref.watch(workoutSummariesStreamProvider);
    return Scaffold(
      body: SafeArea(
        child: workoutsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Error: $e', textAlign: TextAlign.center),
            ),
          ),
          data: (summaries) {
            if (summaries.isEmpty) {
              return const _EmptyState();
            }
            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: summaries.length,
              itemBuilder: (context, i) {
                final s = summaries[i];
                return InkWell(
                  onTap: () => _start(context, ref, s.workout),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          s.workout.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          s.exerciseCount == 1
                              ? '1 exercise'
                              : '${s.exerciseCount} exercises',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _start(
    BuildContext context,
    WidgetRef ref,
    Workout workout,
  ) async {
    final db = ref.read(databaseProvider);
    final full = await db.loadFullWorkout(workout.id);
    if (full == null || full.exercises.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout has no exercises')),
      );
      return;
    }
    final hasSets = full.exercises.any((e) => e.plannedSets.isNotEmpty);
    if (!hasSets) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout has no planned sets')),
      );
      return;
    }
    final session = await db.startSession(workout.id);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WatchRunPage(workout: full, sessionId: session.id),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'No workouts.\nCreate one on the phone.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
