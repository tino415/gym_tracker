import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../sync/sync_service.dart';
import 'watch_run_page.dart';

class WatchPickRoutinePage extends ConsumerWidget {
  const WatchPickRoutinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routinesAsync = ref.watch(routineSummariesStreamProvider);
    return Scaffold(
      body: SafeArea(
        child: routinesAsync.when(
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
              itemCount: summaries.length + 1,
              itemBuilder: (context, i) {
                if (i == summaries.length) {
                  return InkWell(
                    onTap: () => _sync(context, ref),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 12,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.sync, size: 18),
                          const SizedBox(width: 6),
                          Text(
                            'Sync',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final s = summaries[i];
                return InkWell(
                  onTap: () => _start(context, ref, s.routine),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          s.routine.name,
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
    Routine routine,
  ) async {
    final db = ref.read(databaseProvider);
    final full = await db.loadFullRoutine(routine.id);
    if (full == null || full.exercises.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Routine has no exercises')));
      return;
    }
    final hasSets = full.exercises.any((e) => e.plannedSets.isNotEmpty);
    if (!hasSets) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Routine has no planned sets')),
      );
      return;
    }
    if (!context.mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => WatchRunPage(routine: full)));
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(syncServiceProvider).pushAll();
    if (!context.mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Sync pushed')));
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
          'No routines.\nCreate one on the phone.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
