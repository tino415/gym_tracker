import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../../sync/sync_service.dart';

class HistoryListPage extends ConsumerWidget {
  const HistoryListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workoutsAsync = ref.watch(recentWorkoutsStreamProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: RefreshIndicator(
        // On the Firestore-direct web build there's no SyncService (Firestore
        // snapshots are already live); pull-to-refresh is a no-op there.
        onRefresh: () => ref.read(firestoreDirectProvider)
            ? Future<void>.value()
            : ref.read(syncServiceProvider).pushAll(),
        child: workoutsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              ListView(children: [Center(child: Text('Error: $e'))]),
          data: (workouts) {
            if (workouts.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [_EmptyState()],
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: workouts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final w = workouts[i];
                return ListTile(
                  title: Text(w.routineName ?? 'Workout'),
                  subtitle: Text(_subtitle(w)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/history/${w.syncId}'),
                );
              },
            );
          },
        ),
      ),
    );
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
