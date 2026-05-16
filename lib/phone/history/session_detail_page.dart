import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/providers.dart';

class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({super.key, required this.sessionId});

  final int sessionId;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage> {
  Session? _session;
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
    final sessions = await db.watchRecentSessions().first;
    final session = sessions.where((s) => s.id == widget.sessionId).firstOrNull;
    final completions = await db.completionsForSession(widget.sessionId);
    for (final c in completions) {
      if (_exerciseNameCache.containsKey(c.plannedSetId)) continue;
      final ps = await (db.select(db.plannedSets)
            ..where((t) => t.id.equals(c.plannedSetId)))
          .getSingleOrNull();
      if (ps == null) continue;
      final we = await (db.select(db.workoutExercises)
            ..where((t) => t.id.equals(ps.workoutExerciseId)))
          .getSingleOrNull();
      if (we == null) continue;
      final ex = await (db.select(db.exercises)
            ..where((t) => t.id.equals(we.exerciseId)))
          .getSingleOrNull();
      if (ex == null) continue;
      _exerciseNameCache[c.plannedSetId] = ex.name;
    }
    if (!mounted) return;
    setState(() {
      _session = session;
      _completions = completions;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Session')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Session')),
        body: const Center(child: Text('Session not found')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Session')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Started: ${_session!.startedAt}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (_session!.endedAt != null)
            Text(
              'Ended: ${_session!.endedAt}',
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
