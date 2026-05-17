import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../sync/sync_service.dart';

class RoutinesListPage extends ConsumerWidget {
  const RoutinesListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routinesAsync = ref.watch(routineSummariesStreamProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Routines')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/routines/new'),
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncServiceProvider).pushAll(),
        child: routinesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              ListView(children: [Center(child: Text('Error: $e'))]),
          data: (summaries) {
            if (summaries.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [_EmptyState()],
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: summaries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = summaries[i];
                return ListTile(
                  title: Text(s.routine.name),
                  subtitle: Text(
                    s.exerciseCount == 1
                        ? '1 exercise'
                        : '${s.exerciseCount} exercises',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/routines/${s.routine.id}'),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 64),
          Icon(
            Icons.fitness_center,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          const Text(
            'No routines yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to design your first routine.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Pull down to sync with the watch.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
