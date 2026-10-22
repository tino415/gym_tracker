import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../l10n/l10n.dart';
import '../sync/sync_service.dart';
import '../sync/workout_bridge.dart';
import 'watch_run_page.dart';
import 'watch_snack.dart';
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
              child: Text(context.l10n.watchError('$e'), textAlign: TextAlign.center),
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
                    context,
                    summaries,
                    inProgress.routineId,
                  );
                  return _ResumeCard(
                    routineName: name,
                    onTap: () => _resume(context, inProgress.syncId),
                    onLongPress: () => _confirmDiscard(
                      context,
                      ref,
                      inProgress.syncId,
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
                            context.l10n.watchSync,
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
                          context.l10n.watchExerciseCount(s.exerciseCount),
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

  String _routineNameFor(
    BuildContext context,
    List<RoutineSummary> summaries,
    String? routineId,
  ) {
    final fallback = context.l10n.watchWorkoutFallbackName;
    if (routineId == null) return fallback;
    for (final s in summaries) {
      if (s.routine.syncId == routineId) return s.routine.name;
    }
    return fallback;
  }

  void _resume(BuildContext context, String workoutId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WatchRunPage(resumeWorkoutId: workoutId),
      ),
    );
  }

  Future<void> _confirmDiscard(
    BuildContext context,
    WidgetRef ref,
    String workoutId,
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
    final full = await db.loadFullRoutine(routine.syncId);
    if (full == null || full.exercises.isEmpty) {
      if (!context.mounted) return;
      showWatchSnack(context, context.l10n.watchRoutineNoExercises);
      return;
    }
    final hasSets = full.exercises.any((e) => e.plannedSets.isNotEmpty);
    if (!hasSets) {
      if (!context.mounted) return;
      showWatchSnack(context, context.l10n.watchRoutineNoPlannedSets);
      return;
    }
    if (!context.mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => WatchRunPage(routine: full)));
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    await ref.read(syncServiceProvider).pushAll();
    if (!context.mounted) return;
    showWatchSnack(context, context.l10n.watchSyncPushed);
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
                      context.l10n.watchResume,
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
                  context.l10n.watchLongPressToDiscard,
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
          context.l10n.watchNoRoutines,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
