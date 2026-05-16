import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';

class WorkoutsListPage extends ConsumerWidget {
  const WorkoutsListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workoutsAsync = ref.watch(workoutSummariesStreamProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Workouts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/workouts/new'),
        child: const Icon(Icons.add),
      ),
      body: workoutsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (summaries) {
          if (summaries.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            itemCount: summaries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = summaries[i];
              return ListTile(
                title: Text(s.workout.name),
                subtitle: Text(
                  s.exerciseCount == 1
                      ? '1 exercise'
                      : '${s.exerciseCount} exercises',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/workouts/${s.workout.id}'),
              );
            },
          );
        },
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.fitness_center,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text(
              'No workouts yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to design your first workout.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
