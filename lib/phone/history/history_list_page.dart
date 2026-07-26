import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../../sync/sync_service.dart';
import '../breakpoints.dart';
import '../wide_master_detail.dart';
import 'workout_detail_page.dart';

/// Workouts home (route `/history`). Narrow: single-pane list that pushes the
/// workout detail. Wide (desktop web): master-detail split with the workout
/// detail inline — see [masterDetailBreakpoint].
class HistoryListPage extends ConsumerWidget {
  const HistoryListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= masterDetailBreakpoint;
    if (wide) {
      return WideMasterDetail(
        title: 'Workouts',
        addTooltip: 'Log workout',
        onAdd: (api) async {
          final id = await logPastWorkout(context, ref);
          if (id != null) api.select(id);
        },
        listBuilder: (onSelect, selectedId) =>
            WorkoutsListView(onSelect: onSelect, selectedId: selectedId),
        detailBuilder: (selectedId, isDraft, onDeleted, onCreated) =>
            WorkoutDetailPage(
          workoutId: selectedId!,
          embedded: true,
          onDeleted: onDeleted,
        ),
        placeholder: const MasterDetailPlaceholder(
          icon: Icons.history,
          label: 'Select a workout to view or edit.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Workouts')),
      body: RefreshIndicator(
        // On the Firestore-direct web build there's no SyncService (Firestore
        // snapshots are already live); pull-to-refresh is a no-op there.
        onRefresh: () => ref.read(firestoreDirectProvider)
            ? Future<void>.value()
            : ref.read(syncServiceProvider).pushAll(),
        child: WorkoutsListView(
          onSelect: (id) => context.push('/history/$id'),
          alwaysScrollable: true,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final id = await logPastWorkout(context, ref);
          if (id != null && context.mounted) context.push('/history/$id');
        },
        icon: const Icon(Icons.add),
        label: const Text('Log workout'),
      ),
    );
  }
}

/// List body — loading / error / empty / list of workouts — shared by the
/// narrow page and the wide pane. [selectedId] highlights the current row.
class WorkoutsListView extends ConsumerWidget {
  const WorkoutsListView({
    super.key,
    required this.onSelect,
    this.selectedId,
    this.alwaysScrollable = false,
  });

  final void Function(String syncId) onSelect;
  final String? selectedId;

  /// Force the list scrollable even when short, so a wrapping [RefreshIndicator]
  /// can be pulled on the narrow page. Off in the wide pane (no pull-to-refresh).
  final bool alwaysScrollable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workoutsAsync = ref.watch(recentWorkoutsStreamProvider);
    final physics =
        alwaysScrollable ? const AlwaysScrollableScrollPhysics() : null;
    return workoutsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ListView(physics: physics, children: [Center(child: Text('Error: $e'))]),
      data: (workouts) {
        if (workouts.isEmpty) {
          return ListView(
            physics: physics,
            children: const [_EmptyState()],
          );
        }
        return ListView.separated(
          physics: physics,
          itemCount: workouts.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final w = workouts[i];
            return ListTile(
              selected: w.syncId == selectedId,
              title: Text(w.routineName ?? 'Workout'),
              subtitle: Text(_subtitle(w)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onSelect(w.syncId),
            );
          },
        );
      },
    );
  }
}

/// Backfill a workout done off-watch: pick a routine to prefill (or start
/// empty), pick the day, create the workout, and return its syncId so the caller
/// can open the detail editor (push on narrow, select on wide) to fill in the
/// actuals. Returns null if the user cancels at any step.
Future<String?> logPastWorkout(BuildContext context, WidgetRef ref) async {
  final summaries =
      await ref.read(routineRepositoryProvider).watchRoutineSummaries().first;
  if (!context.mounted) return null;

  final choice = await showModalBottomSheet<_BackfillChoice>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Log a past workout',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Empty workout'),
            subtitle: const Text('Add exercises yourself'),
            onTap: () =>
                Navigator.of(ctx).pop(const _BackfillChoice(routineId: null)),
          ),
          if (summaries.isNotEmpty) const Divider(),
          for (final s in summaries)
            ListTile(
              leading: const Icon(Icons.fitness_center),
              title: Text(s.routine.name),
              subtitle: Text(
                s.exerciseCount == 1
                    ? '1 exercise'
                    : '${s.exerciseCount} exercises',
              ),
              onTap: () => Navigator.of(ctx)
                  .pop(_BackfillChoice(routineId: s.routine.syncId)),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return null;

  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: DateTime(2000),
    lastDate: now,
  );
  if (date == null || !context.mounted) return null;
  // Keep the current time-of-day; the detail editor refines start/end.
  final started =
      DateTime(date.year, date.month, date.day, now.hour, now.minute);

  final workout = await ref.read(workoutRepositoryProvider).createWorkout(
        routineId: choice.routineId,
        startedAt: started,
        endedAt: started,
      );
  return workout.syncId;
}

/// A user's pick in the "log past workout" sheet. A null [routineId] means an
/// empty workout; the sheet returning null (not this) means it was dismissed.
class _BackfillChoice {
  const _BackfillChoice({required this.routineId});
  final String? routineId;
}

/// Date + status/duration, e.g. "2026-07-25 12:25 · 48 min" or
/// "2026-07-25 12:25 · In progress".
String _subtitle(Workout w) {
  final date = _formatDate(w.startedAt);
  if (w.endedAt == null) return '$date · In progress';
  return '$date · ${_duration(w.startedAt, w.endedAt!)}';
}

String _duration(DateTime start, DateTime end) {
  final mins = end.difference(start).inMinutes;
  if (mins < 1) return '<1 min';
  if (mins < 60) return '$mins min';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

String _formatDate(DateTime dt) {
  final y = dt.year;
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
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
            Icons.history,
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
            'Completed workouts will appear here.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
