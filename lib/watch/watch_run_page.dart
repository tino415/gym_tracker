import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../sync/sync_service.dart';
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
  late int _reps;
  late double _weightKg;
  _Phase _phase = _Phase.logSet;
  int _restSecondsLeft = 0;
  Timer? _timer;

  int? _workoutId;
  Map<int, SetCompletion> _completions = const {};
  StreamSubscription<Map<int, SetCompletion>>? _completionsSub;

  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    final first = _firstNonEmpty(widget.routine);
    _exerciseIdx = first?.eIdx ?? 0;
    _setIdx = first?.sIdx ?? 0;
    _loadCurrentSetTargets();
  }

  Future<void> _startWorkout() async {
    final db = ref.read(databaseProvider);
    final workout = await db.startWorkout(widget.routine.routine.id);
    if (!mounted) return;
    _completionsSub = db.watchCompletionsByPlannedSet(workout.id).listen((map) {
      if (!mounted) return;
      setState(() => _completions = map);
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
    _completionsSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  int get _totalPlannedSets {
    var total = 0;
    for (final e in widget.routine.exercises) {
      total += e.plannedSets.length;
    }
    return total;
  }

  ({int eIdx, int sIdx})? _firstNonEmpty(FullRoutine r) {
    for (var i = 0; i < r.exercises.length; i++) {
      if (r.exercises[i].plannedSets.isNotEmpty) {
        return (eIdx: i, sIdx: 0);
      }
    }
    return null;
  }

  ({int eIdx, int sIdx})? _nextAfter(int eIdx, int sIdx) {
    final exercises = widget.routine.exercises;
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

  ({int eIdx, int sIdx})? _prevBefore(int eIdx, int sIdx) {
    final exercises = widget.routine.exercises;
    if (sIdx > 0) {
      return (eIdx: eIdx, sIdx: sIdx - 1);
    }
    for (var i = eIdx - 1; i >= 0; i--) {
      if (exercises[i].plannedSets.isNotEmpty) {
        return (eIdx: i, sIdx: exercises[i].plannedSets.length - 1);
      }
    }
    return null;
  }

  PlannedSet get _currentSet =>
      widget.routine.exercises[_exerciseIdx].plannedSets[_setIdx];

  FullRoutineExercise get _currentExercise =>
      widget.routine.exercises[_exerciseIdx];

  bool get _currentIsCompleted => _completions.containsKey(_currentSet.id);

  void _loadCurrentSetTargets() {
    final s = _currentSet;
    final existing = _completions[s.id];
    if (existing != null) {
      _reps = existing.actualReps;
      _weightKg = existing.actualWeightKg;
    } else {
      _reps = s.targetReps;
      _weightKg = s.targetWeightKg;
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

  Future<void> _toggleDone() async {
    final workoutId = _workoutId;
    if (workoutId == null) return;
    final db = ref.read(databaseProvider);
    final wasCompleted = _currentIsCompleted;
    if (wasCompleted) {
      await db.deleteSetCompletionFor(
        workoutId: workoutId,
        plannedSetId: _currentSet.id,
      );
      // Stay on the set — let the user edit and re-mark, or navigate.
      return;
    }
    await db.upsertSetCompletion(
      workoutId: workoutId,
      plannedSetId: _currentSet.id,
      actualReps: _reps,
      actualWeightKg: _weightKg,
    );
    // Predict post-write count (stream callback hasn't necessarily fired yet).
    final newCount = _completions.length + 1;
    if (newCount >= _totalPlannedSets) {
      // All sets complete — don't auto-finish. User taps Finish on the
      // exercise list page when they're ready.
      HapticFeedback.heavyImpact();
      return;
    }
    _startRest(_currentExercise.routineExercise.restSeconds);
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

  Future<void> _finishWorkout() async {
    final workoutId = _workoutId;
    if (workoutId == null) return;
    _timer?.cancel();
    final db = ref.read(databaseProvider);
    await db.finishWorkout(workoutId);
    // Best-effort sync to the paired phone — fails silently if unpaired.
    unawaited(ref.read(syncServiceProvider).pushWorkout(workoutId));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            WatchWorkoutDonePage(routineName: widget.routine.routine.name),
      ),
    );
  }

  void _jumpToExercise(int eIdx) {
    if (_workoutId == null) return;
    final ex = widget.routine.exercises[eIdx];
    if (ex.plannedSets.isEmpty) return;
    // Land on the first incomplete set in that exercise; fall back to 0.
    var sIdx = 0;
    for (var i = 0; i < ex.plannedSets.length; i++) {
      if (!_completions.containsKey(ex.plannedSets[i].id)) {
        sIdx = i;
        break;
      }
      // If every set is complete, sIdx stays at 0 (re-show first).
    }
    final allDone = ex.plannedSets.every((p) => _completions.containsKey(p.id));
    if (allDone) sIdx = 0;
    _goTo(eIdx, sIdx);
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.routine.exercises.every((e) => e.plannedSets.isEmpty)) {
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
    final onExerciseList =
        !_pageController.hasClients ||
        (_pageController.page ?? _pageController.initialPage.toDouble()) < 0.5;
    return PopScope(
      // While a workout is in progress and we're on the log/rest page,
      // intercept back so it returns to the exercise list (with the Finish
      // button) instead of popping back to the routine picker.
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
              ? _LogSetView(
                  exerciseName: _currentExercise.exercise.name,
                  setIndex: _setIdx,
                  totalSets: _currentExercise.plannedSets.length,
                  reps: _reps,
                  weightKg: _weightKg,
                  completed: _currentIsCompleted,
                  hasPrev: _prevBefore(_exerciseIdx, _setIdx) != null,
                  hasNext: _nextAfter(_exerciseIdx, _setIdx) != null,
                  ambient: true,
                  onRepsChanged: (_) {},
                  onWeightChanged: (_) {},
                  onToggleDone: _toggleDone,
                  onPrev: () {},
                  onNext: () {},
                )
              : PageView(
                  controller: _pageController,
                  onPageChanged: (_) => setState(() {}),
                  children: [
                    _ExerciseListView(
                      routine: widget.routine,
                      completions: _completions,
                      totalPlannedSets: _totalPlannedSets,
                      currentExerciseIdx: _exerciseIdx,
                      started: _workoutId != null,
                      onPickExercise: _jumpToExercise,
                      onStart: _startWorkout,
                      onFinish: _finishWorkout,
                    ),
                    switch (_phase) {
                      _Phase.logSet => _LogSetView(
                        exerciseName: _currentExercise.exercise.name,
                        setIndex: _setIdx,
                        totalSets: _currentExercise.plannedSets.length,
                        reps: _reps,
                        weightKg: _weightKg,
                        completed: _currentIsCompleted,
                        hasPrev: _prevBefore(_exerciseIdx, _setIdx) != null,
                        hasNext: _nextAfter(_exerciseIdx, _setIdx) != null,
                        ambient: false,
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
                      ),
                      _Phase.rest => _RestView(
                        secondsLeft: _restSecondsLeft,
                        upNext: _upNextLabel(),
                        ambient: widget.ambient,
                        onSkip: _skipRest,
                        onAdd15: () => _bumpRest(15),
                        onSub15: () => _bumpRest(-15),
                      ),
                    },
                  ],
                ),
        ),
      ),
    );
  }

  String? _upNextLabel() {
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) return null;
    final ex = widget.routine.exercises[next.eIdx];
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
    required this.completed,
    required this.hasPrev,
    required this.hasNext,
    required this.ambient,
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
  final bool ambient;
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
    final muted = ambient
        ? Colors.white70
        : Theme.of(context).colorScheme.onSurface;
    if (ambient) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(exerciseName, style: TextStyle(color: muted, fontSize: 14)),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
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
          ),
          StepperValue<double>(
            value: weightKg,
            step: 2.5,
            min: 0,
            formatter: (v) => _formatWeight(v),
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
          SizedBox(
            width: double.infinity,
            child: completed
                ? FilledButton.tonal(
                    onPressed: onToggleDone,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: const Text('Done ✓'),
                  )
                : FilledButton(
                    onPressed: onToggleDone,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
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
    required this.routine,
    required this.completions,
    required this.totalPlannedSets,
    required this.currentExerciseIdx,
    required this.started,
    required this.onPickExercise,
    required this.onStart,
    required this.onFinish,
  });

  final FullRoutine routine;
  final Map<int, SetCompletion> completions;
  final int totalPlannedSets;
  final int currentExerciseIdx;
  final bool started;
  final void Function(int eIdx) onPickExercise;
  final VoidCallback onStart;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allDone =
        totalPlannedSets > 0 && completions.length >= totalPlannedSets;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Text(
            routine.routine.name,
            style: theme.textTheme.titleSmall,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              itemCount: routine.exercises.length,
              itemBuilder: (context, i) {
                final ex = routine.exercises[i];
                final total = ex.plannedSets.length;
                final done = ex.plannedSets
                    .where((p) => completions.containsKey(p.id))
                    .length;
                final isCurrent = i == currentExerciseIdx;
                final tappable = started && total > 0;
                return InkWell(
                  onTap: tappable ? () => onPickExercise(i) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            ex.exercise.name,
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
                          started ? '$done/$total' : '$total sets',
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
                : FilledButton(onPressed: onStart, child: const Text('Start')),
          ),
        ],
      ),
    );
  }
}
