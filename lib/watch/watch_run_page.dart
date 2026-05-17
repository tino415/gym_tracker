import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../sync/sync_service.dart';
import 'superset_nav.dart';
import 'watch_workout_done_page.dart';
import 'widgets/stepper_button.dart';

class WatchRunPage extends ConsumerStatefulWidget {
  const WatchRunPage({super.key, required this.routine, this.ambient = false});

  final FullRoutine routine;
  final bool ambient;

  @override
  ConsumerState<WatchRunPage> createState() => _WatchRunPageState();
}

enum _Phase { logSet, rest }

class _WatchRunPageState extends ConsumerState<WatchRunPage> {
  late int _exerciseIdx;
  late int _setIdx;

  // Reps-kind input buffer.
  int _reps = 0;
  double _weightKg = 0;

  // Time-kind input buffer. _timeRemaining is the displayed countdown; once
  // _timeRunning is true the periodic timer ticks it down (negative is fine).
  int _timeRemaining = 0;
  bool _timeRunning = false;
  // Captures the target the timer was started against so we can compute
  // elapsed = startTarget - timeRemaining on Done.
  int _timeStartTarget = 0;

  _Phase _phase = _Phase.logSet;
  int _restSecondsLeft = 0;
  Timer? _timer;

  int? _workoutId;
  FullWorkout? _snapshot;
  StreamSubscription<FullWorkout?>? _snapshotSub;
  // True once we've consumed the first snapshot emission and seeded our
  // input buffers. Subsequent emissions update `_snapshot` for the exercise
  // list / completion badges but must NOT reload targets — otherwise a sync
  // push or any DB write would cancel a running rest/countdown timer.
  bool _initialLoadDone = false;

  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    final first = _firstNonEmptyPreview(widget.routine);
    _exerciseIdx = first?.eIdx ?? 0;
    _setIdx = first?.sIdx ?? 0;
  }

  Future<void> _startWorkout() async {
    final db = ref.read(databaseProvider);
    final workout = await db.startWorkout(widget.routine.routine.id);
    if (!mounted) return;
    _snapshotSub = db.watchFullWorkout(workout.id).listen((snap) {
      if (!mounted || snap == null) return;
      setState(() {
        _snapshot = snap;
        if (!_initialLoadDone) {
          _initialLoadDone = true;
          final firstUnstarted = _firstNonEmptySnapshot(snap);
          if (_exerciseIdx >= snap.exercises.length) {
            _exerciseIdx = firstUnstarted?.eIdx ?? 0;
            _setIdx = firstUnstarted?.sIdx ?? 0;
          }
          _loadCurrentSetTargets();
        }
      });
    });
    setState(() => _workoutId = workout.id);
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _snapshotSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // --- Navigation helpers -------------------------------------------------

  ({int eIdx, int sIdx})? _firstNonEmptyPreview(FullRoutine r) {
    for (var i = 0; i < r.exercises.length; i++) {
      if (r.exercises[i].plannedSets.isNotEmpty) {
        return (eIdx: i, sIdx: 0);
      }
    }
    return null;
  }

  ({int eIdx, int sIdx})? _firstNonEmptySnapshot(FullWorkout snap) {
    for (var i = 0; i < snap.exercises.length; i++) {
      if (snap.exercises[i].sets.isNotEmpty) {
        return (eIdx: i, sIdx: 0);
      }
    }
    return null;
  }

  int _exerciseCount() {
    if (_snapshot != null) return _snapshot!.exercises.length;
    return widget.routine.exercises.length;
  }

  int _setCount(int eIdx) {
    if (_snapshot != null) return _snapshot!.exercises[eIdx].sets.length;
    return widget.routine.exercises[eIdx].plannedSets.length;
  }

  int? _supersetGroupAt(int eIdx) {
    if (_snapshot != null) {
      return _snapshot!.exercises[eIdx].workoutExercise.supersetGroup;
    }
    return widget.routine.exercises[eIdx].routineExercise.supersetGroup;
  }

  SupersetSeq get _seq => SupersetSeq(
    exerciseCount: _exerciseCount(),
    setCountAt: _setCount,
    supersetGroupAt: _supersetGroupAt,
  );

  ({int eIdx, int sIdx})? _nextAfter(int eIdx, int sIdx) =>
      _seq.nextAfter(eIdx, sIdx);

  ({int eIdx, int sIdx})? _prevBefore(int eIdx, int sIdx) =>
      _seq.prevBefore(eIdx, sIdx);

  ({int first, int last})? _groupBounds(int eIdx) {
    final group = _supersetGroupAt(eIdx);
    if (group == null) return null;
    var first = eIdx;
    while (first > 0 && _supersetGroupAt(first - 1) == group) {
      first--;
    }
    var last = eIdx;
    while (last + 1 < _exerciseCount() &&
        _supersetGroupAt(last + 1) == group) {
      last++;
    }
    return (first: first, last: last);
  }

  String _currentKind() {
    if (_snapshot != null) return _snapshot!.exercises[_exerciseIdx].kind;
    return widget.routine.exercises[_exerciseIdx].kind;
  }

  String _currentExerciseName() {
    if (_snapshot != null) {
      return _snapshot!.exercises[_exerciseIdx].workoutExercise.exerciseName;
    }
    return widget.routine.exercises[_exerciseIdx].exercise.name;
  }

  int _currentRestSeconds() {
    // In a superset, rest is one shared interval after the round — use the
    // first exercise of the contiguous group as the canonical rest source.
    final group = _groupBounds(_exerciseIdx);
    final useEIdx = group?.first ?? _exerciseIdx;
    if (_snapshot != null) {
      return _snapshot!.exercises[useEIdx].workoutExercise.restSeconds;
    }
    return widget.routine.exercises[useEIdx].routineExercise.restSeconds;
  }

  /// The current set's workoutSetId, if a snapshot has been taken.
  int? _currentWorkoutSetId() {
    if (_snapshot == null) return null;
    final ex = _snapshot!.exercises[_exerciseIdx];
    if (_setIdx >= ex.sets.length) return null;
    return ex.sets[_setIdx].workoutSet.id;
  }

  SetCompletion? _currentCompletion() {
    if (_snapshot == null) return null;
    final ex = _snapshot!.exercises[_exerciseIdx];
    if (_setIdx >= ex.sets.length) return null;
    return ex.sets[_setIdx].completion;
  }

  bool get _currentIsCompleted => _currentCompletion() != null;

  void _loadCurrentSetTargets() {
    _timer?.cancel();
    _timeRunning = false;
    final kind = _currentKind();
    final completion = _currentCompletion();
    if (_snapshot != null) {
      final ws = _snapshot!.exercises[_exerciseIdx].sets[_setIdx].workoutSet;
      if (kind == exerciseKindTime) {
        _timeStartTarget = ws.targetSeconds ?? 30;
        if (completion?.actualSeconds != null) {
          // Reflect a past completion as a "completed" timer state.
          _timeRemaining = _timeStartTarget - completion!.actualSeconds!;
        } else {
          _timeRemaining = _timeStartTarget;
        }
        // Time-based sets can optionally track weight too (loaded carries,
        // weighted holds, etc.). Pull a sensible default; 0 if untouched.
        _weightKg = completion?.actualWeightKg ?? (ws.targetWeightKg ?? 0);
      } else {
        _reps = completion?.actualReps ?? (ws.targetReps ?? 10);
        _weightKg =
            completion?.actualWeightKg ?? (ws.targetWeightKg ?? 20);
      }
    } else {
      // Preview before Start.
      final ps = widget.routine.exercises[_exerciseIdx].plannedSets[_setIdx];
      if (kind == exerciseKindTime) {
        _timeStartTarget = ps.targetSeconds ?? 30;
        _timeRemaining = _timeStartTarget;
        _weightKg = ps.targetWeightKg ?? 0;
      } else {
        _reps = ps.targetReps ?? 10;
        _weightKg = ps.targetWeightKg ?? 20;
      }
    }
  }

  void _goTo(int eIdx, int sIdx) {
    _timer?.cancel();
    setState(() {
      _exerciseIdx = eIdx;
      _setIdx = sIdx;
      _phase = _Phase.logSet;
      _loadCurrentSetTargets();
    });
  }

  // --- Reps & time mark/unmark -------------------------------------------

  Future<void> _toggleDone() async {
    final workoutId = _workoutId;
    final wsId = _currentWorkoutSetId();
    if (workoutId == null || wsId == null) return;
    final db = ref.read(databaseProvider);
    if (_currentIsCompleted) {
      await db.deleteSetCompletionFor(workoutId: workoutId, workoutSetId: wsId);
      return;
    }
    final kind = _currentKind();
    if (kind == exerciseKindTime) {
      final elapsed = max(0, _timeStartTarget - _timeRemaining);
      _timer?.cancel();
      _timeRunning = false;
      await db.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: wsId,
        actualSeconds: elapsed,
        actualWeightKg: _weightKg > 0 ? _weightKg : null,
      );
    } else {
      await db.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: wsId,
        actualReps: _reps,
        actualWeightKg: _weightKg,
      );
    }
    HapticFeedback.heavyImpact();
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) return;
    if (next.sIdx == _setIdx) {
      // Same round, different exercise (superset) — immediate advance.
      _goTo(next.eIdx, next.sIdx);
    } else {
      // New round (or new standalone exercise) — rest first.
      _startRest(_currentRestSeconds());
    }
  }

  // --- Rest timer ---------------------------------------------------------

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
        _advanceAfterRest();
      } else {
        setState(() => _restSecondsLeft -= 1);
      }
    });
  }

  void _skipRest() {
    _timer?.cancel();
    _advanceAfterRest();
  }

  void _bumpRest(int delta) {
    setState(() {
      _restSecondsLeft = max(1, _restSecondsLeft + delta);
    });
  }

  void _advanceAfterRest() {
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) {
      setState(() => _phase = _Phase.logSet);
      return;
    }
    setState(() {
      _exerciseIdx = next.eIdx;
      _setIdx = next.sIdx;
      _phase = _Phase.logSet;
      _loadCurrentSetTargets();
    });
  }

  // --- Time-based set countdown ------------------------------------------

  void _toggleTimeRun() {
    if (_timeRunning) {
      _timer?.cancel();
      setState(() => _timeRunning = false);
      return;
    }
    setState(() => _timeRunning = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_timeRunning) {
        t.cancel();
        return;
      }
      setState(() => _timeRemaining -= 1);
      if (_timeRemaining == 0) {
        HapticFeedback.mediumImpact();
      }
    });
  }

  // --- Finish -------------------------------------------------------------

  Future<void> _finishWorkout() async {
    final workoutId = _workoutId;
    if (workoutId == null) return;
    _timer?.cancel();
    final db = ref.read(databaseProvider);
    await db.finishWorkout(workoutId);
    unawaited(ref.read(syncServiceProvider).pushWorkout(workoutId));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            WatchWorkoutDonePage(routineName: widget.routine.routine.name),
      ),
    );
  }

  // --- Exercise list jump -------------------------------------------------

  void _jumpToExercise(int eIdx) {
    if (_workoutId == null) return;
    if (_setCount(eIdx) == 0) return;
    var sIdx = 0;
    // Land on the first incomplete set in that exercise.
    if (_snapshot != null) {
      final ex = _snapshot!.exercises[eIdx];
      for (var i = 0; i < ex.sets.length; i++) {
        if (ex.sets[i].completion == null) {
          sIdx = i;
          break;
        }
      }
      final allDone = ex.sets.every((s) => s.completion != null);
      if (allDone) sIdx = 0;
    }
    _goTo(eIdx, sIdx);
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  // --- Build --------------------------------------------------------------

  String? _upNextLabel() {
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) return null;
    if (_snapshot != null) {
      return _snapshot!.exercises[next.eIdx].workoutExercise.exerciseName;
    }
    return widget.routine.exercises[next.eIdx].exercise.name;
  }

  bool _hasAnySets() {
    if (_snapshot != null) {
      return _snapshot!.exercises.any((e) => e.sets.isNotEmpty);
    }
    return widget.routine.exercises.any((e) => e.plannedSets.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasAnySets()) {
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
    final onExerciseList = !_pageController.hasClients ||
        (_pageController.page ?? _pageController.initialPage.toDouble()) < 0.5;
    return PopScope(
      canPop: _workoutId == null || onExerciseList || widget.ambient,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _pageController.animateToPage(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      },
      child: Scaffold(
        backgroundColor: widget.ambient ? Colors.black : null,
        body: SafeArea(
          child: widget.ambient
              ? _buildAmbient(context)
              : PageView(
                  controller: _pageController,
                  onPageChanged: (_) => setState(() {}),
                  children: [
                    _ExerciseListView(
                      exercises: _exerciseListItems(),
                      currentExerciseIdx: _exerciseIdx,
                      routineName: widget.routine.routine.name,
                      started: _workoutId != null,
                      allDone: _allDone(),
                      onPick: _jumpToExercise,
                      onStart: _startWorkout,
                      onFinish: _finishWorkout,
                    ),
                    _buildRunPane(context),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildAmbient(BuildContext context) {
    final kind = _currentKind();
    final name = _currentExerciseName();
    final muted = Colors.white70;
    String value;
    if (kind == exerciseKindTime) {
      value = '${_timeRemaining}s';
    } else {
      final w = _weightKg;
      final wStr = w == w.roundToDouble()
          ? w.toStringAsFixed(0)
          : w.toStringAsFixed(1);
      value = '${wStr}kg × $_reps';
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(name, style: TextStyle(color: muted, fontSize: 14)),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(color: muted, fontSize: 20)),
        ],
      ),
    );
  }

  Widget _buildRunPane(BuildContext context) {
    if (_phase == _Phase.rest) {
      return _RestView(
        secondsLeft: _restSecondsLeft,
        upNext: _upNextLabel(),
        ambient: widget.ambient,
        onSkip: _skipRest,
        onAdd15: () => _bumpRest(15),
        onSub15: () => _bumpRest(-15),
      );
    }
    final hasPrev = _prevBefore(_exerciseIdx, _setIdx) != null;
    final hasNext = _nextAfter(_exerciseIdx, _setIdx) != null;
    if (_currentKind() == exerciseKindTime) {
      return _TimeSetView(
        exerciseName: _currentExerciseName(),
        setIndex: _setIdx,
        totalSets: _setCount(_exerciseIdx),
        secondsRemaining: _timeRemaining,
        running: _timeRunning,
        weightKg: _weightKg,
        completed: _currentIsCompleted,
        hasPrev: hasPrev,
        hasNext: hasNext,
        onWeightChanged: (v) => setState(() => _weightKg = v),
        onToggleRun: _toggleTimeRun,
        onToggleDone: _toggleDone,
        onPrev: () {
          final p = _prevBefore(_exerciseIdx, _setIdx);
          if (p != null) _goTo(p.eIdx, p.sIdx);
        },
        onNext: () {
          final n = _nextAfter(_exerciseIdx, _setIdx);
          if (n != null) _goTo(n.eIdx, n.sIdx);
        },
      );
    }
    return _RepsSetView(
      exerciseName: _currentExerciseName(),
      setIndex: _setIdx,
      totalSets: _setCount(_exerciseIdx),
      reps: _reps,
      weightKg: _weightKg,
      completed: _currentIsCompleted,
      hasPrev: hasPrev,
      hasNext: hasNext,
      onRepsChanged: (v) => setState(() => _reps = v),
      onWeightChanged: (v) => setState(() => _weightKg = v),
      onToggleDone: _toggleDone,
      onPrev: () {
        final p = _prevBefore(_exerciseIdx, _setIdx);
        if (p != null) _goTo(p.eIdx, p.sIdx);
      },
      onNext: () {
        final n = _nextAfter(_exerciseIdx, _setIdx);
        if (n != null) _goTo(n.eIdx, n.sIdx);
      },
    );
  }

  List<_ExerciseListItem> _exerciseListItems() {
    if (_snapshot != null) {
      return [
        for (final e in _snapshot!.exercises)
          _ExerciseListItem(
            name: e.workoutExercise.exerciseName,
            totalSets: e.sets.length,
            doneSets:
                e.sets.where((s) => s.completion != null).length,
            supersetGroup: e.workoutExercise.supersetGroup,
            kind: e.kind,
          ),
      ];
    }
    return [
      for (final e in widget.routine.exercises)
        _ExerciseListItem(
          name: e.exercise.name,
          totalSets: e.plannedSets.length,
          doneSets: 0,
          supersetGroup: e.routineExercise.supersetGroup,
          kind: e.kind,
        ),
    ];
  }

  bool _allDone() {
    if (_snapshot == null) return false;
    if (_snapshot!.exercises.isEmpty) return false;
    for (final e in _snapshot!.exercises) {
      for (final s in e.sets) {
        if (s.completion == null) return false;
      }
    }
    return true;
  }
}

class _ExerciseListItem {
  const _ExerciseListItem({
    required this.name,
    required this.totalSets,
    required this.doneSets,
    required this.supersetGroup,
    required this.kind,
  });

  final String name;
  final int totalSets;
  final int doneSets;
  final int? supersetGroup;
  final String kind;
}

class _RepsSetView extends StatelessWidget {
  const _RepsSetView({
    required this.exerciseName,
    required this.setIndex,
    required this.totalSets,
    required this.reps,
    required this.weightKg,
    required this.completed,
    required this.hasPrev,
    required this.hasNext,
    required this.onRepsChanged,
    required this.onWeightChanged,
    required this.onToggleDone,
    required this.onPrev,
    required this.onNext,
  });

  final String exerciseName;
  final int setIndex;
  final int totalSets;
  final int reps;
  final double weightKg;
  final bool completed;
  final bool hasPrev;
  final bool hasNext;
  final ValueChanged<int> onRepsChanged;
  final ValueChanged<double> onWeightChanged;
  final VoidCallback onToggleDone;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  String _formatWeight(double w) {
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _setHeader(
            context,
            exerciseName: exerciseName,
            setIndex: setIndex,
            totalSets: totalSets,
            hasPrev: hasPrev,
            hasNext: hasNext,
            onPrev: onPrev,
            onNext: onNext,
          ),
          StepperValue<double>(
            value: weightKg,
            step: 2.5,
            min: 0,
            formatter: _formatWeight,
            suffix: 'kg',
            onChanged: onWeightChanged,
          ),
          StepperValue<int>(
            value: reps,
            step: 1,
            min: 1,
            formatter: (v) => v.toString(),
            suffix: 'reps',
            onChanged: onRepsChanged,
          ),
          _doneButton(completed: completed, onTap: onToggleDone),
        ],
      ),
    );
  }
}

class _TimeSetView extends StatelessWidget {
  const _TimeSetView({
    required this.exerciseName,
    required this.setIndex,
    required this.totalSets,
    required this.secondsRemaining,
    required this.running,
    required this.weightKg,
    required this.completed,
    required this.hasPrev,
    required this.hasNext,
    required this.onWeightChanged,
    required this.onToggleRun,
    required this.onToggleDone,
    required this.onPrev,
    required this.onNext,
  });

  final String exerciseName;
  final int setIndex;
  final int totalSets;
  final int secondsRemaining;
  final bool running;
  final double weightKg;
  final bool completed;
  final bool hasPrev;
  final bool hasNext;
  final ValueChanged<double> onWeightChanged;
  final VoidCallback onToggleRun;
  final VoidCallback onToggleDone;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  String _formatWeight(double w) {
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final big = theme.textTheme.headlineMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: secondsRemaining < 0 ? theme.colorScheme.error : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _setHeader(
            context,
            exerciseName: exerciseName,
            setIndex: setIndex,
            totalSets: totalSets,
            hasPrev: hasPrev,
            hasNext: hasNext,
            onPrev: onPrev,
            onNext: onNext,
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('${secondsRemaining}s', style: big),
          ),
          StepperValue<double>(
            value: weightKg,
            step: 2.5,
            min: 0,
            formatter: _formatWeight,
            suffix: 'kg',
            onChanged: onWeightChanged,
          ),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onToggleRun,
              icon: Icon(running ? Icons.pause : Icons.play_arrow, size: 18),
              label: Text(running ? 'Pause' : 'Start'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(32),
              ),
            ),
          ),
          _doneButton(completed: completed, onTap: onToggleDone),
        ],
      ),
    );
  }
}

Widget _setHeader(
  BuildContext context, {
  required String exerciseName,
  required int setIndex,
  required int totalSets,
  required bool hasPrev,
  required bool hasNext,
  required VoidCallback onPrev,
  required VoidCallback onNext,
}) {
  return Row(
    children: [
      SizedBox(
        width: 28,
        child: IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          iconSize: 18,
          onPressed: hasPrev ? onPrev : null,
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous set',
        ),
      ),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
          ],
        ),
      ),
      SizedBox(
        width: 28,
        child: IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          iconSize: 18,
          onPressed: hasNext ? onNext : null,
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Next set',
        ),
      ),
    ],
  );
}

Widget _doneButton({required bool completed, required VoidCallback onTap}) {
  final style = FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(32),
    padding: const EdgeInsets.symmetric(horizontal: 12),
  );
  return SizedBox(
    width: double.infinity,
    child: completed
        ? FilledButton.tonal(
            onPressed: onTap,
            style: style,
            child: const Text('Done ✓'),
          )
        : FilledButton(
            onPressed: onTap,
            style: style,
            child: const Text('Done'),
          ),
  );
}

class _RestView extends StatelessWidget {
  const _RestView({
    required this.secondsLeft,
    required this.upNext,
    required this.ambient,
    required this.onSkip,
    required this.onAdd15,
    required this.onSub15,
  });

  final int secondsLeft;
  final String? upNext;
  final bool ambient;
  final VoidCallback onSkip;
  final VoidCallback onAdd15;
  final VoidCallback onSub15;

  @override
  Widget build(BuildContext context) {
    final muted = ambient
        ? Colors.white70
        : Theme.of(context).colorScheme.onSurface;
    final big = TextStyle(
      fontSize: ambient ? 36 : 36,
      fontWeight: FontWeight.w300,
      color: muted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Text('Rest', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          if (ambient)
            Text('${secondsLeft}s', style: big)
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  onPressed: onSub15,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove, size: 18),
                  tooltip: '-15s',
                ),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text('${secondsLeft}s', style: big),
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: onAdd15,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: '+15s',
                ),
              ],
            ),
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

class _ExerciseListView extends StatelessWidget {
  const _ExerciseListView({
    required this.exercises,
    required this.currentExerciseIdx,
    required this.routineName,
    required this.started,
    required this.allDone,
    required this.onPick,
    required this.onStart,
    required this.onFinish,
  });

  final List<_ExerciseListItem> exercises;
  final int currentExerciseIdx;
  final String routineName;
  final bool started;
  final bool allDone;
  final void Function(int eIdx) onPick;
  final VoidCallback onStart;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Text(
            routineName,
            style: theme.textTheme.titleSmall,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              itemCount: exercises.length,
              itemBuilder: (context, i) {
                final ex = exercises[i];
                final tappable = started && ex.totalSets > 0;
                final isCurrent = i == currentExerciseIdx;
                return InkWell(
                  onTap: tappable ? () => onPick(i) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: Row(
                      children: [
                        if (ex.supersetGroup != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.link,
                              size: 14,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        if (ex.kind == exerciseKindTime)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.timer_outlined,
                              size: 14,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            ex.name,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: isCurrent && started
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          started
                              ? '${ex.doneSets}/${ex.totalSets}'
                              : '${ex.totalSets} sets',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: started
                ? FilledButton(
                    onPressed: allDone ? onFinish : null,
                    child: const Text('Finish'),
                  )
                : FilledButton(
                    onPressed: onStart,
                    child: const Text('Start'),
                  ),
          ),
        ],
      ),
    );
  }
}
