import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../sync/sync_service.dart';
import '../sync/workout_bridge.dart';
import 'watch_run_page.dart';
import 'widgets/discard_dialog.dart';
import 'widgets/round_safe_area.dart';

class WatchPickRoutinePage extends ConsumerWidget {
  const WatchPickRoutinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routinesAsync = ref.watch(routineSummariesStreamProvider);
    final inProgress = ref.watch(inProgressWorkoutStreamProvider).valueOrNull;
    return Scaffold(
      body: RoundSafeArea(
        child: routinesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Error: $e', textAlign: TextAlign.center),
            ),
          ),
          data: (summaries) {
            if (summaries.isEmpty && inProgress == null) {
              return const _EmptyState();
            }
            // On round watches, push the first/last item past the chord so
            // they aren't clipped at the top/bottom of the screen.
            final isRound = WatchShapeScope.of(context);
            final vGap = isRound ? 36.0 : 8.0;
            final resumeCount = inProgress == null ? 0 : 1;
            final itemCount = resumeCount + summaries.length + 1;
            return ListView.builder(
              padding: EdgeInsets.fromLTRB(16, vGap, 16, vGap),
              itemCount: itemCount,
              itemBuilder: (context, i) {
                if (inProgress != null && i == 0) {
                  final name = _routineNameFor(
                    summaries,
                    inProgress.routineId,
                  );
                  return _ResumeCard(
                    routineName: name,
                    onTap: () => _resume(context, inProgress.id),
                    onLongPress: () => _confirmDiscard(
                      context,
                      ref,
                      inProgress.id,
                      name,
                    ),
                  );
                }
                if (i == itemCount - 1) {
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
                final s = summaries[i - resumeCount];
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
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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

  String _routineNameFor(List<RoutineSummary> summaries, int? routineId) {
    if (routineId == null) return 'Workout';
    for (final s in summaries) {
      if (s.routine.id == routineId) return s.routine.name;
    }
    return 'Workout';
  }

  void _resume(BuildContext context, int workoutId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WatchRunPage(resumeWorkoutId: workoutId),
      ),
    );
  }

  Future<void> _confirmDiscard(
    BuildContext context,
    WidgetRef ref,
    int workoutId,
    String routineName,
  ) async {
    final ok = await DiscardDialog.show(context, routineName: routineName);
    if (!ok) return;
    await ref.read(databaseProvider).deleteWorkout(workoutId);
    // Service may still be running from this workout — stop it too so the
    // ongoing chip clears.
    unawaited(WorkoutBridge.instance.stop());
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

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({
    required this.routineName,
    required this.onTap,
    required this.onLongPress,
  });

  final String routineName;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 14,
              horizontal: 14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.play_arrow,
                      size: 16,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Resume',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  routineName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'long-press to discard',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
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
          'No routines.\nCreate one on the phone.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
