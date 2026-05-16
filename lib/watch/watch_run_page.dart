import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../sync/sync_service.dart';
import 'watch_session_done_page.dart';
import 'widgets/stepper_button.dart';

class WatchRunPage extends ConsumerStatefulWidget {
  const WatchRunPage({
    super.key,
    required this.workout,
    required this.sessionId,
    this.ambient = false,
  });

  final FullWorkout workout;
  final int sessionId;
  final bool ambient;

  @override
  ConsumerState<WatchRunPage> createState() => _WatchRunPageState();
}

enum _Phase { logSet, rest }

class _WatchRunPageState extends ConsumerState<WatchRunPage> {
  late int _exerciseIdx;
  late int _setIdx;
  late int _reps;
  late double _weightKg;
  _Phase _phase = _Phase.logSet;
  int _restSecondsLeft = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final first = _firstNonEmpty(widget.workout);
    _exerciseIdx = first?.eIdx ?? 0;
    _setIdx = first?.sIdx ?? 0;
    _loadCurrentSetTargets();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  ({int eIdx, int sIdx})? _firstNonEmpty(FullWorkout w) {
    for (var i = 0; i < w.exercises.length; i++) {
      if (w.exercises[i].plannedSets.isNotEmpty) {
        return (eIdx: i, sIdx: 0);
      }
    }
    return null;
  }

  ({int eIdx, int sIdx})? _nextAfter(int eIdx, int sIdx) {
    final exercises = widget.workout.exercises;
    if (sIdx + 1 < exercises[eIdx].plannedSets.length) {
      return (eIdx: eIdx, sIdx: sIdx + 1);
    }
    for (var i = eIdx + 1; i < exercises.length; i++) {
      if (exercises[i].plannedSets.isNotEmpty) {
        return (eIdx: i, sIdx: 0);
      }
    }
    return null;
  }

  PlannedSet get _currentSet =>
      widget.workout.exercises[_exerciseIdx].plannedSets[_setIdx];

  FullWorkoutExercise get _currentExercise =>
      widget.workout.exercises[_exerciseIdx];

  void _loadCurrentSetTargets() {
    final s = _currentSet;
    _reps = s.targetReps;
    _weightKg = s.targetWeightKg;
  }

  Future<void> _markDone() async {
    final db = ref.read(databaseProvider);
    final completedExerciseIdx = _exerciseIdx;
    final completedSetIdx = _setIdx;
    await db.recordSetCompletion(
      sessionId: widget.sessionId,
      plannedSetId: _currentSet.id,
      actualReps: _reps,
      actualWeightKg: _weightKg,
    );
    final next = _nextAfter(completedExerciseIdx, completedSetIdx);
    if (next == null) {
      await db.finishSession(widget.sessionId);
      // Best-effort sync to the paired phone — fails silently if unpaired.
      unawaited(ref.read(syncServiceProvider).pushSession(widget.sessionId));
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => WatchSessionDonePage(
            workoutName: widget.workout.workout.name,
          ),
        ),
      );
      return;
    }
    _startRest(_currentExercise.workoutExercise.restSeconds);
  }

  void _startRest(int seconds) {
    _timer?.cancel();
    setState(() {
      _phase = _Phase.rest;
      _restSecondsLeft = seconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_restSecondsLeft <= 1) {
        t.cancel();
        HapticFeedback.heavyImpact();
        _advanceToNextSet();
      } else {
        setState(() => _restSecondsLeft -= 1);
      }
    });
  }

  void _skipRest() {
    _timer?.cancel();
    _advanceToNextSet();
  }

  void _advanceToNextSet() {
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) {
      return; // shouldn't happen — _markDone handled the terminal case.
    }
    setState(() {
      _exerciseIdx = next.eIdx;
      _setIdx = next.sIdx;
      _phase = _Phase.logSet;
      _loadCurrentSetTargets();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.workout.exercises.every((e) => e.plannedSets.isEmpty)) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'No planned sets.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: widget.ambient ? Colors.black : null,
      body: SafeArea(
        child: switch (_phase) {
          _Phase.logSet => _LogSetView(
              exerciseName: _currentExercise.exercise.name,
              setIndex: _setIdx,
              totalSets: _currentExercise.plannedSets.length,
              reps: _reps,
              weightKg: _weightKg,
              ambient: widget.ambient,
              onRepsChanged: (v) => setState(() => _reps = v),
              onWeightChanged: (v) => setState(() => _weightKg = v),
              onMarkDone: _markDone,
            ),
          _Phase.rest => _RestView(
              secondsLeft: _restSecondsLeft,
              upNext: _upNextLabel(),
              ambient: widget.ambient,
              onSkip: _skipRest,
            ),
        },
      ),
    );
  }

  String? _upNextLabel() {
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) return null;
    final ex = widget.workout.exercises[next.eIdx];
    return ex.exercise.name;
  }
}

class _LogSetView extends StatelessWidget {
  const _LogSetView({
    required this.exerciseName,
    required this.setIndex,
    required this.totalSets,
    required this.reps,
    required this.weightKg,
    required this.ambient,
    required this.onRepsChanged,
    required this.onWeightChanged,
    required this.onMarkDone,
  });

  final String exerciseName;
  final int setIndex;
  final int totalSets;
  final int reps;
  final double weightKg;
  final bool ambient;
  final ValueChanged<int> onRepsChanged;
  final ValueChanged<double> onWeightChanged;
  final VoidCallback onMarkDone;

  String _formatWeight(double w) {
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final muted = ambient
        ? Colors.white70
        : Theme.of(context).colorScheme.onSurface;
    if (ambient) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              exerciseName,
              style: TextStyle(color: muted, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              '${_formatWeight(weightKg)}kg × $reps',
              style: TextStyle(color: muted, fontSize: 20),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Text(
            exerciseName,
            style: Theme.of(context).textTheme.titleSmall,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            'Set ${setIndex + 1}/$totalSets',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          StepperValue<double>(
            value: weightKg,
            step: 2.5,
            min: 0,
            formatter: (v) => _formatWeight(v),
            suffix: 'kg',
            onChanged: onWeightChanged,
          ),
          const SizedBox(height: 8),
          StepperValue<int>(
            value: reps,
            step: 1,
            min: 1,
            formatter: (v) => v.toString(),
            suffix: 'reps',
            onChanged: onRepsChanged,
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onMarkDone,
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RestView extends StatelessWidget {
  const _RestView({
    required this.secondsLeft,
    required this.upNext,
    required this.ambient,
    required this.onSkip,
  });

  final int secondsLeft;
  final String? upNext;
  final bool ambient;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final muted = ambient
        ? Colors.white70
        : Theme.of(context).colorScheme.onSurface;
    final big = TextStyle(
      fontSize: ambient ? 40 : 56,
      fontWeight: FontWeight.w300,
      color: muted,
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Text('Rest', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          Text('${secondsLeft}s', style: big),
          if (upNext != null) ...[
            const SizedBox(height: 8),
            Text(
              'Up next: $upNext',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Spacer(),
          if (!ambient)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onSkip,
                child: const Text('Skip'),
              ),
            ),
        ],
      ),
    );
  }
}
