import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../sync/sync_service.dart';
import '../sync/workout_bridge.dart';
import 'set_target_format.dart';
import 'superset_nav.dart';
import 'watch_alternative_picker_page.dart';
import 'watch_exercise_preview_page.dart';
import 'watch_workout_done_page.dart';
import 'widgets/discard_dialog.dart';
import 'widgets/round_safe_area.dart';
import 'widgets/stepper_button.dart';

class WatchRunPage extends ConsumerStatefulWidget {
  const WatchRunPage({
    super.key,
    this.routine,
    this.resumeWorkoutId,
    this.resumeRoutineName,
    this.ambient = false,
  }) : assert(
         routine != null || resumeWorkoutId != null,
         'WatchRunPage needs either a routine to start or a workoutId to resume',
       );

  /// Routine to start a fresh workout from. Null in resume mode.
  final FullRoutine? routine;

  /// When non-null, attach to this existing in-progress workout instead of
  /// starting a new one.
  final int? resumeWorkoutId;

  /// Display name to use for the ongoing-activity chip before the workout
  /// snapshot has been loaded. Only meaningful when [resumeWorkoutId] is set.
  final String? resumeRoutineName;
  final bool ambient;

  @override
  ConsumerState<WatchRunPage> createState() => _WatchRunPageState();
}

enum _Phase { logSet, rest }

class _WatchRunPageState extends ConsumerState<WatchRunPage>
    with WidgetsBindingObserver {
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
  // Mirror of `_restSecondsLeft` exposed to off-route observers (the exercise
  // preview pushed on top reads this so its rest pill ticks down without us
  // rebuilding the whole run page from a parent route).
  final ValueNotifier<int> _restSecondsLeftVN = ValueNotifier<int>(0);
  // `_timer` is now a display-only ticker that recomputes the countdown from a
  // wall-clock anchor each second. The authoritative completion + vibration is
  // scheduled natively (survives screen-off); these anchors hold the absolute
  // end time and double as idempotency guards for the completion paths.
  Timer? _timer;
  DateTime? _restEndTime;
  DateTime? _timeEndTime;
  // True while we believe the native service has a vibration scheduled for the
  // active countdown. If arming it failed (no bridge, platform error, service
  // not live) we fall back to a Dart haptic at completion so a buzz is never
  // silently lost. One flag suffices — only one countdown runs at a time.
  bool _nativeTimerArmed = false;
  // One-shot guard for the fallback buzz at the time-set's target crossing.
  bool _timeTargetBuzzed = false;
  // Set once the workout has ended (finish/discard) so dispose() won't re-issue
  // clearTimer() — which would resurrect the just-stopped foreground service.
  bool _serviceStopped = false;
  StreamSubscription<String>? _timerDoneSub;

  int? _workoutId;
  FullWorkout? _snapshot;
  StreamSubscription<FullWorkout?>? _snapshotSub;

  // "Last time" panel for the current set position. Token guards against races
  // when the user advances faster than the lookup completes.
  SetCompletion? _lastCompletion;
  int _lastCompletionToken = 0;
  // True once we've consumed the first snapshot emission and seeded our
  // input buffers. Subsequent emissions update `_snapshot` for the exercise
  // list / completion badges but must NOT reload targets — otherwise a sync
  // push or any DB write would cancel a running rest/countdown timer.
  bool _initialLoadDone = false;

  HeartRateSample? _hrSample;
  StreamSubscription<HeartRateSample>? _hrSub;
  // Drops the badge if no fresh sample arrives within the window. Re-armed
  // on every received sample.
  Timer? _hrStaleTimer;
  // BPMs captured since the user landed on the current set. Cleared whenever
  // the active set changes; consumed on Done to compute per-set avg + max.
  final List<int> _setHrBpms = [];

  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final routine = widget.routine;
    if (routine != null) {
      final first = _firstNonEmptyPreview(routine);
      _exerciseIdx = first?.eIdx ?? 0;
      _setIdx = first?.sIdx ?? 0;
    }
    if (widget.resumeWorkoutId != null) {
      // Attach to the existing workout on the next frame so initState can
      // finish (ref.read can't run before the widget is mounted into the
      // tree).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_startWorkout());
      });
    }

    _hrSub = WorkoutBridge.instance.heartRateStream.listen(_onHeartRate);
    _timerDoneSub =
        WorkoutBridge.instance.timerDoneStream.listen(_onNativeTimerDone);
  }

  void _onHeartRate(HeartRateSample sample) {
    if (!mounted) return;
    _hrStaleTimer?.cancel();
    // Only collect samples while actively logging a set (not during rest, not
    // before the workout starts) so per-set aggregates reflect the work
    // interval rather than the recovery window.
    if (_workoutId != null && _phase == _Phase.logSet) {
      _setHrBpms.add(sample.bpm);
    }
    setState(() => _hrSample = sample);
    _hrStaleTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      setState(() => _hrSample = null);
    });
  }

  Future<void> _startWorkout() async {
    final db = ref.read(databaseProvider);
    // Best-effort permissions so Health Services can sample heart rate and
    // the ongoing notification can render. Denial is non-fatal — the workout
    // still proceeds, just without HR/chip.
    await WorkoutBridge.instance.requestPermissions();
    if (!mounted) return;
    final int workoutId;
    if (widget.resumeWorkoutId != null) {
      workoutId = widget.resumeWorkoutId!;
    } else {
      final w = await db.startWorkout(widget.routine!.routine.id);
      if (!mounted) return;
      workoutId = w.id;
    }
    unawaited(
      WorkoutBridge.instance.start(routineName: _routineName()),
    );
    _snapshotSub = db.watchFullWorkout(workoutId).listen((snap) {
      if (!mounted || snap == null) return;
      setState(() {
        _snapshot = snap;
        if (!_initialLoadDone) {
          _initialLoadDone = true;
          final seed = widget.resumeWorkoutId != null
              ? _firstIncompleteSnapshot(snap) ?? _firstNonEmptySnapshot(snap)
              : _firstNonEmptySnapshot(snap);
          if (seed != null &&
              (widget.resumeWorkoutId != null ||
                  _exerciseIdx >= snap.exercises.length)) {
            _exerciseIdx = seed.eIdx;
            _setIdx = seed.sIdx;
          }
          _loadCurrentSetTargets();
        }
      });
    });
    setState(() => _workoutId = workoutId);
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _hrStaleTimer?.cancel();
    _hrSub?.cancel();
    _timerDoneSub?.cancel();
    _snapshotSub?.cancel();
    // Cancel any pending native vibration so it can't fire after we're gone —
    // but not if we already stopped the service (finish/discard). Re-issuing
    // clearTimer after stop would startService a fresh, orphaned instance.
    if (!_serviceStopped) unawaited(WorkoutBridge.instance.clearTimer());
    _pageController.dispose();
    _restSecondsLeftVN.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // While the screen was off our periodic ticker was frozen, but the
    // wall-clock anchor and the native countdown were not. On resume, jump the
    // display to the correct value — or, if the anchor has already passed,
    // complete now (native already vibrated while we were paused).
    if (state != AppLifecycleState.resumed) return;
    final now = clock.now();
    if (_phase == _Phase.rest && _restEndTime != null) {
      if (now.isAfter(_restEndTime!)) {
        _onRestElapsed();
      } else {
        _startUiTicker();
        _tickCountdown();
      }
    } else if (_timeRunning && _timeEndTime != null) {
      // Overtime keeps counting into negative; just re-sync the display. The
      // native buzz at the target already fired while we were paused.
      _startUiTicker();
      _tickCountdown();
    }
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

  /// First (exerciseIdx, setIdx) in the snapshot that has no completion yet.
  /// Used in resume mode to skip past already-logged sets.
  ({int eIdx, int sIdx})? _firstIncompleteSnapshot(FullWorkout snap) =>
      _firstIncompleteSnapshotExcept(snap, null);

  /// Like [_firstIncompleteSnapshot] but skips a specific workout_set id. Used
  /// after auto-advance when the just-completed set may not yet be reflected
  /// in the snapshot stream.
  ({int eIdx, int sIdx})? _firstIncompleteSnapshotExcept(
    FullWorkout snap,
    int? excludeWorkoutSetId,
  ) {
    for (var i = 0; i < snap.exercises.length; i++) {
      final ex = snap.exercises[i];
      for (var j = 0; j < ex.sets.length; j++) {
        final s = ex.sets[j];
        if (s.workoutSet.id == excludeWorkoutSetId) continue;
        if (s.completion == null) return (eIdx: i, sIdx: j);
      }
    }
    return null;
  }

  int _exerciseCount() {
    if (_snapshot != null) return _snapshot!.exercises.length;
    return widget.routine!.exercises.length;
  }

  int _setCount(int eIdx) {
    if (_snapshot != null) return _snapshot!.exercises[eIdx].sets.length;
    return widget.routine!.exercises[eIdx].plannedSets.length;
  }

  int? _supersetGroupAt(int eIdx) {
    if (_snapshot != null) {
      return _snapshot!.exercises[eIdx].workoutExercise.supersetGroup;
    }
    return widget.routine!.exercises[eIdx].routineExercise.supersetGroup;
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
    return widget.routine!.exercises[_exerciseIdx].kind;
  }

  String _currentExerciseName() {
    if (_snapshot != null) {
      return _snapshot!.exercises[_exerciseIdx].workoutExercise.exerciseName;
    }
    return widget.routine!.exercises[_exerciseIdx].exercise.name;
  }

  int _currentRestSeconds() {
    // In a superset, rest is one shared interval after the round — use the
    // first exercise of the contiguous group as the canonical rest source.
    final group = _groupBounds(_exerciseIdx);
    final useEIdx = group?.first ?? _exerciseIdx;
    if (_snapshot != null) {
      return _snapshot!.exercises[useEIdx].workoutExercise.restSeconds;
    }
    return widget.routine!.exercises[useEIdx].routineExercise.restSeconds;
  }

  String _routineName() =>
      _snapshot?.routine?.name ??
      widget.routine?.routine.name ??
      widget.resumeRoutineName ??
      'Workout';

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

  Future<void> _refreshLastCompletion() async {
    final wid = _workoutId;
    if (wid == null || _snapshot == null) {
      if (mounted && _lastCompletion != null) {
        setState(() => _lastCompletion = null);
      }
      return;
    }
    final we = _snapshot!.exercises[_exerciseIdx].workoutExercise;
    final eid = we.exerciseId;
    if (eid == null) {
      if (mounted && _lastCompletion != null) {
        setState(() => _lastCompletion = null);
      }
      return;
    }
    final token = ++_lastCompletionToken;
    final r = await ref.read(databaseProvider).lastCompletionForExerciseAtSetIndex(
      exerciseId: eid,
      setIndex: _setIdx,
      excludeWorkoutId: wid,
    );
    if (!mounted || token != _lastCompletionToken) return;
    setState(() => _lastCompletion = r);
  }

  void _loadCurrentSetTargets() {
    _timer?.cancel();
    // Leaving the current set cancels any running countdown — drop the native
    // vibration too so a stale buzz can't fire on the next set.
    _cancelNativeCountdown();
    _timeRunning = false;
    unawaited(_refreshLastCompletion());
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
      final ps = widget.routine!.exercises[_exerciseIdx].plannedSets[_setIdx];
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
    _restSecondsLeftVN.value = 0;
    _setHrBpms.clear();
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
    // Per-set HR aggregates. Absent semantics so re-Done with no new samples
    // preserves a previously-saved value.
    Value<int?> avgHr = const Value.absent();
    Value<int?> maxHr = const Value.absent();
    if (_setHrBpms.isNotEmpty) {
      final sum = _setHrBpms.reduce((a, b) => a + b);
      avgHr = Value((sum / _setHrBpms.length).round());
      maxHr = Value(_setHrBpms.reduce(max));
    }
    final kind = _currentKind();
    if (kind == exerciseKindTime) {
      final elapsed = max(0, _timeStartTarget - _timeRemaining);
      _timer?.cancel();
      _timeRunning = false;
      // Done pressed mid-hold (or in overtime): cancel the pending native fire.
      _cancelNativeCountdown();
      await db.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: wsId,
        actualSeconds: elapsed,
        actualWeightKg: _weightKg > 0 ? _weightKg : null,
        avgHeartRate: avgHr,
        maxHeartRate: maxHr,
      );
    } else {
      await db.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: wsId,
        actualReps: _reps,
        actualWeightKg: _weightKg,
        avgHeartRate: avgHr,
        maxHeartRate: maxHr,
      );
    }
    HapticFeedback.heavyImpact();
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next != null) {
      if (next.sIdx == _setIdx) {
        // Same round, different exercise (superset) — immediate advance.
        _goTo(next.eIdx, next.sIdx);
      } else {
        // New round (or new standalone exercise) — rest first.
        _startRest(_currentRestSeconds());
      }
      return;
    }
    // Forward sequence exhausted — wrap back to the first set still missing
    // a completion (skipped earlier in the workout). Excluding `wsId` is
    // defensive: the snapshot stream may not yet reflect the upsert we just
    // performed.
    final snap = _snapshot;
    if (snap != null &&
        _firstIncompleteSnapshotExcept(snap, wsId) != null) {
      _startRest(_currentRestSeconds());
      return;
    }
    // Workout is genuinely complete — stay on logSet so the user can Finish.
  }

  // --- Rest timer ---------------------------------------------------------

  // Display-only ticker. Both countdowns recompute remaining = end - now each
  // second; the native service owns the authoritative fire + vibration.
  void _startUiTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      _tickCountdown();
    });
  }

  void _tickCountdown() {
    final now = clock.now();
    if (_phase == _Phase.rest && _restEndTime != null) {
      final remaining =
          (_restEndTime!.difference(now).inMilliseconds / 1000).ceil();
      if (remaining <= 0) {
        _onRestElapsed();
      } else {
        setState(() => _restSecondsLeft = remaining);
        _restSecondsLeftVN.value = remaining;
      }
    } else if (_timeRunning && _timeEndTime != null) {
      // Counts past 0 into negative (overtime) so a hold kept past target logs
      // the extra seconds (`_toggleDone` does startTarget - remaining). ceil
      // matches the rest display and shows the target for its full first
      // second. The native vibration fires once at the target; if it wasn't
      // armed, buzz here at the 0 crossing instead.
      final remaining =
          (_timeEndTime!.difference(now).inMilliseconds / 1000).ceil();
      setState(() => _timeRemaining = remaining);
      if (remaining <= 0 && !_timeTargetBuzzed) {
        _timeTargetBuzzed = true;
        if (!_nativeTimerArmed) HapticFeedback.mediumImpact();
      }
    }
  }

  void _onNativeTimerDone(String kind) {
    if (!mounted) return;
    if (kind == kTimerKindRest) {
      _onRestElapsed();
    } else if (kind == kTimerKindTime) {
      // Native vibrated at the target; the hold keeps running into overtime.
      // Just suppress the Dart fallback buzz.
      _timeTargetBuzzed = true;
    }
  }

  // Arms (or, when [schedule] is false, deliberately skips) the native
  // vibration for the active countdown and records whether it succeeded, so
  // completion can fall back to a Dart haptic if the native path failed.
  void _armNativeTimer(String kind, DateTime end, {bool schedule = true}) {
    if (!schedule) {
      _nativeTimerArmed = false;
      return;
    }
    _nativeTimerArmed = true; // optimistic; flipped false if the call fails
    WorkoutBridge.instance
        .setTimer(kind: kind, endTimeMs: end.millisecondsSinceEpoch)
        .then((ok) {
      if (mounted && !ok) _nativeTimerArmed = false;
    });
  }

  // Drop the active countdown's wall-clock anchor and recall its pending native
  // vibration. Idempotent; safe to call when nothing is armed.
  void _cancelNativeCountdown() {
    if (_restEndTime == null && _timeEndTime == null && !_nativeTimerArmed) {
      return;
    }
    _restEndTime = null;
    _timeEndTime = null;
    _nativeTimerArmed = false;
    unawaited(WorkoutBridge.instance.clearTimer());
  }

  void _startRest(int seconds) {
    _timer?.cancel();
    final end = clock.now().add(Duration(seconds: seconds));
    _restEndTime = end;
    setState(() {
      _phase = _Phase.rest;
      _restSecondsLeft = seconds;
    });
    _restSecondsLeftVN.value = seconds;
    // A zero-length rest has no future instant to schedule — completion (and
    // its fallback buzz) is handled by the immediate Dart tick.
    _armNativeTimer(kTimerKindRest, end, schedule: seconds > 0);
    _startUiTicker();
  }

  // Single completion path for rest. Native is the buzzer when armed; if it
  // wasn't, we buzz here so the rest-over signal is never lost. Nulling the
  // anchor first makes this idempotent, so whichever of the Dart ticker /
  // native event / resume reconciliation arrives first wins.
  void _onRestElapsed() {
    if (_phase != _Phase.rest || _restEndTime == null) return;
    _restEndTime = null;
    _timer?.cancel();
    _restSecondsLeftVN.value = 0;
    if (!_nativeTimerArmed) HapticFeedback.heavyImpact();
    _advanceAfterRest();
  }

  void _skipRest() {
    _timer?.cancel();
    _restSecondsLeftVN.value = 0;
    _cancelNativeCountdown();
    _advanceAfterRest();
  }

  void _bumpRest(int delta) {
    if (_restEndTime == null) return;
    final floor = clock.now().add(const Duration(seconds: 1));
    var end = _restEndTime!.add(Duration(seconds: delta));
    if (end.isBefore(floor)) end = floor;
    _restEndTime = end;
    final remaining =
        (end.difference(clock.now()).inMilliseconds / 1000).ceil();
    setState(() => _restSecondsLeft = remaining);
    _restSecondsLeftVN.value = remaining;
    _armNativeTimer(kTimerKindRest, end);
  }

  void _advanceAfterRest() {
    _restEndTime = null;
    var next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) {
      final snap = _snapshot;
      if (snap != null) {
        next = _firstIncompleteSnapshotExcept(snap, _currentWorkoutSetId());
      }
    }
    if (next == null) {
      setState(() => _phase = _Phase.logSet);
      return;
    }
    _setHrBpms.clear();
    setState(() {
      _exerciseIdx = next!.eIdx;
      _setIdx = next.sIdx;
      _phase = _Phase.logSet;
      _loadCurrentSetTargets();
    });
  }

  // --- Time-based set countdown ------------------------------------------

  void _toggleTimeRun() {
    if (_timeRunning) {
      // Pause.
      _timer?.cancel();
      _cancelNativeCountdown();
      setState(() => _timeRunning = false);
      return;
    }
    final secs = _timeRemaining;
    final end = clock.now().add(Duration(seconds: secs));
    _timeEndTime = end;
    // Already at/past the target (re-running an over-completed set): the buzz
    // point is behind us, so don't schedule a native fire or a fallback buzz.
    _timeTargetBuzzed = secs <= 0;
    setState(() => _timeRunning = true);
    _armNativeTimer(kTimerKindTime, end, schedule: secs > 0);
    _startUiTicker();
  }

  // --- Discard ------------------------------------------------------------

  Future<void> _confirmDiscard() async {
    final workoutId = _workoutId;
    if (workoutId == null) return;
    // Capture navigator + db handles up-front so we still have them after the
    // dialog await (mounted-check below guards against a late dispose).
    final navigator = Navigator.of(context);
    final db = ref.read(databaseProvider);
    final ok = await DiscardDialog.show(context, routineName: _routineName());
    if (!ok) return;
    _timer?.cancel();
    // Don't await — cancel takes effect immediately; awaiting can stall the
    // navigation behind a Drift bookkeeping future.
    unawaited(_snapshotSub?.cancel());
    _snapshotSub = null;
    // Defer the pop to the next frame so the dialog's pop animation has
    // fully unwound before we tear down our own route. Without this the pop
    // can race the dialog's own pop transition and silently no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.canPop()) navigator.pop();
    });
    unawaited(db.deleteWorkout(workoutId));
    _serviceStopped = true;
    unawaited(WorkoutBridge.instance.stop());
  }

  // --- Finish -------------------------------------------------------------

  Future<void> _finishWorkout() async {
    final workoutId = _workoutId;
    if (workoutId == null) return;
    _timer?.cancel();
    final db = ref.read(databaseProvider);
    // Roll workout-level HR aggregates up from per-set completions. Mean of
    // per-set means (not population mean — samples per set are uneven and
    // we don't store sample counts), and max of per-set maxes.
    final completions = await db.completionsForWorkout(workoutId);
    final avgs = [
      for (final c in completions)
        if (c.avgHeartRate != null) c.avgHeartRate!,
    ];
    final maxes = [
      for (final c in completions)
        if (c.maxHeartRate != null) c.maxHeartRate!,
    ];
    final int? workoutAvg = avgs.isEmpty
        ? null
        : (avgs.reduce((a, b) => a + b) / avgs.length).round();
    final int? workoutMax = maxes.isEmpty ? null : maxes.reduce(max);
    await db.finishWorkout(
      workoutId,
      avgHeartRate: workoutAvg,
      maxHeartRate: workoutMax,
    );
    unawaited(ref.read(syncServiceProvider).pushWorkout(workoutId));
    _serviceStopped = true;
    unawaited(WorkoutBridge.instance.stop());
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => WatchWorkoutDonePage(
          routineName: _routineName(),
          avgHeartRate: workoutAvg,
          maxHeartRate: workoutMax,
        ),
      ),
    );
  }

  // --- Exercise list jump -------------------------------------------------

  /// Open a read-only preview of the given exercise. Available pre-start and
  /// during an active workout. Never touches `_exerciseIdx` / `_setIdx` or
  /// cancels timers — the preview is purely informational. The "Switch to
  /// this" affordance inside the preview is the only way to make this
  /// exercise active, and it routes through [_jumpToExercise].
  Future<void> _openExercisePreview(int eIdx) async {
    if (_setCount(eIdx) == 0) return;
    final navigator = Navigator.of(context);
    final Widget page;
    if (_snapshot != null) {
      page = WatchExercisePreviewPage.fromWorkout(
        _snapshot!.exercises[eIdx],
        restCountdown: _restSecondsLeftVN,
        onSwitchActive: () {
          navigator.pop();
          _jumpToExercise(eIdx);
        },
      );
    } else {
      page = WatchExercisePreviewPage.fromRoutine(
        widget.routine!.exercises[eIdx],
      );
    }
    await navigator.push(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    // If we were resting when the user opened the preview (and they didn't
    // switch active out of it), slide back to the run pane so the rest
    // countdown is in front of them again. _jumpToExercise has already
    // animated to page 1 in the switch-active case, so this is a no-op there.
    if (_workoutId != null &&
        _phase == _Phase.rest &&
        _pageController.hasClients) {
      _pageController.animateToPage(
        1,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

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

  /// The next set's exercise name plus its formatted target (weight/reps or
  /// seconds), shown during rest so the user can see what's coming. Null when
  /// the current set is the last one.
  ({String name, String target})? _upNextDetail() {
    final next = _nextAfter(_exerciseIdx, _setIdx);
    if (next == null) return null;
    if (_snapshot != null) {
      final ex = _snapshot!.exercises[next.eIdx];
      final ws = ex.sets[next.sIdx].workoutSet;
      return (
        name: ex.workoutExercise.exerciseName,
        target: formatSetTarget(
          kind: ex.kind,
          reps: ws.targetReps,
          weightKg: ws.targetWeightKg,
          seconds: ws.targetSeconds,
        ),
      );
    }
    final ex = widget.routine!.exercises[next.eIdx];
    final ps = ex.plannedSets[next.sIdx];
    return (
      name: ex.exercise.name,
      target: formatSetTarget(
        kind: ex.kind,
        reps: ps.targetReps,
        weightKg: ps.targetWeightKg,
        seconds: ps.targetSeconds,
      ),
    );
  }

  bool _hasAnySets() {
    if (_snapshot != null) {
      return _snapshot!.exercises.any((e) => e.sets.isNotEmpty);
    }
    return widget.routine!.exercises.any((e) => e.plannedSets.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    // Resume mode: wait for the workout snapshot before we can render
    // anything (no `widget.routine` to fall back on).
    if (widget.routine == null && _snapshot == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
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
        body: RoundSafeArea(
          child: widget.ambient
              ? _buildAmbient(context)
              : PageView(
                  controller: _pageController,
                  onPageChanged: (_) => setState(() {}),
                  children: [
                    _ExerciseListView(
                      exercises: _exerciseListItems(),
                      currentExerciseIdx: _exerciseIdx,
                      routineName: _routineName(),
                      started: _workoutId != null,
                      allDone: _allDone(),
                      onPick: _openExercisePreview,
                      onStart: _startWorkout,
                      onFinish: _finishWorkout,
                      onDiscard: _confirmDiscard,
                    ),
                    _buildRunPane(context),
                  ],
                ),
        ),
      ),
    );
  }

  /// Current heart-rate BPM if a fresh sample is available and we're inside
  /// an active workout. Inlined into the set header so it doesn't occlude the
  /// exercise name like the earlier overlay did.
  int? _liveHeartRateBpm() {
    if (_workoutId == null) return null;
    final s = _hrSample;
    if (s == null || !s.isFresh()) return null;
    return s.bpm;
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
      final upNext = _upNextDetail();
      return _RestView(
        secondsLeft: _restSecondsLeft,
        upNextName: upNext?.name,
        upNextTarget: upNext?.target,
        ambient: widget.ambient,
        onSkip: _skipRest,
        onAdd15: () => _bumpRest(15),
        onSub15: () => _bumpRest(-15),
      );
    }
    final hasPrev = _prevBefore(_exerciseIdx, _setIdx) != null;
    final hasNext = _nextAfter(_exerciseIdx, _setIdx) != null;
    final bpm = _liveHeartRateBpm();
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
        heartRateBpm: bpm,
        lastTimeText: _formatLastTimeText(_lastCompletion, exerciseKindTime),
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
        onSwap: _openSwapPicker,
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
      heartRateBpm: bpm,
      lastTimeText: _formatLastTimeText(_lastCompletion, exerciseKindReps),
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
      onSwap: _openSwapPicker,
    );
  }

  static String? _formatLastTimeText(SetCompletion? c, String kind) {
    if (c == null) return null;
    if (kind == exerciseKindTime) {
      final s = c.actualSeconds;
      return s == null ? null : 'Last: ${s}s';
    }
    final reps = c.actualReps;
    final w = c.actualWeightKg;
    if (reps == null) return null;
    if (w == null) return 'Last: $reps reps';
    final weightStr = w == w.roundToDouble()
        ? w.toStringAsFixed(0)
        : w.toStringAsFixed(1);
    return 'Last: $reps × $weightStr kg';
  }

  Future<void> _openSwapPicker() async {
    if (_snapshot == null) return;
    final we = _snapshot!.exercises[_exerciseIdx].workoutExercise;
    final swapped = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WatchAlternativePickerPage(workoutExerciseId: we.id),
      ),
    );
    if (swapped != true) return;
    if (!mounted) return;
    // Snapshot has been re-emitted by the stream; pull fresh targets for the
    // active set since the listener skips target reloads for safety (rest /
    // countdown timers).
    setState(_loadCurrentSetTargets);
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
      for (final e in widget.routine!.exercises)
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
    required this.onSwap,
    this.heartRateBpm,
    this.lastTimeText,
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
  final VoidCallback onSwap;
  final int? heartRateBpm;
  final String? lastTimeText;

  String _formatWeight(double w) {
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    return _ScrollableSetView(
      onSwap: onSwap,
      main: _SetViewScaffold(
        prevEnabled: hasPrev,
        nextEnabled: hasNext,
        onPrev: onPrev,
        onNext: onNext,
        setIndex: setIndex,
        totalSets: totalSets,
        heartRateBpm: heartRateBpm,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: _setHeader(
                context,
                exerciseName: exerciseName,
                lastTimeText: lastTimeText,
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StepperValue<double>(
                    value: weightKg,
                    step: 2.5,
                    min: 0,
                    formatter: _formatWeight,
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
                ],
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _doneButton(
                context: context,
                completed: completed,
                onTap: onToggleDone,
              ),
            ),
          ],
        ),
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
    required this.onSwap,
    this.heartRateBpm,
    this.lastTimeText,
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
  final VoidCallback onSwap;
  final int? heartRateBpm;
  final String? lastTimeText;

  String _formatWeight(double w) {
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final big = theme.textTheme.headlineSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: secondsRemaining < 0 ? theme.colorScheme.error : null,
    );
    final isRound = WatchShapeScope.of(context);
    final hInset = isRound ? 24.0 : 0.0;
    return _ScrollableSetView(
      onSwap: onSwap,
      main: _SetViewScaffold(
        prevEnabled: hasPrev,
        nextEnabled: hasNext,
        onPrev: onPrev,
        onNext: onNext,
        setIndex: setIndex,
        totalSets: totalSets,
        heartRateBpm: heartRateBpm,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: _setHeader(
                context,
                exerciseName: exerciseName,
                lastTimeText: lastTimeText,
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('${secondsRemaining}s', style: big),
                  ),
                  const SizedBox(height: 8),
                  StepperValue<double>(
                    value: weightKg,
                    step: 2.5,
                    min: 0,
                    formatter: _formatWeight,
                    suffix: 'kg',
                    onChanged: onWeightChanged,
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: hInset),
                    child: OutlinedButton.icon(
                      onPressed: onToggleRun,
                      icon: Icon(
                        running ? Icons.pause : Icons.play_arrow,
                        size: 16,
                      ),
                      label: Text(running ? 'Pause' : 'Start'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(26),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _doneButton(
                context: context,
                completed: completed,
                onTap: onToggleDone,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lays out a set view's main content with side rails for the prev/next
/// chevrons and (right side) the live heart-rate badge. Uses Stack so the
/// rails don't compete with the center column for the viewport's
/// fractional-pixel width; previous Row + Expanded layout reported a
/// sub-pixel overflow on round faces.
class _SetViewScaffold extends StatelessWidget {
  const _SetViewScaffold({
    required this.child,
    required this.prevEnabled,
    required this.nextEnabled,
    required this.onPrev,
    required this.onNext,
    required this.setIndex,
    required this.totalSets,
    this.heartRateBpm,
  });

  final Widget child;
  final bool prevEnabled;
  final bool nextEnabled;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final int setIndex;
  final int totalSets;
  final int? heartRateBpm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            // Leave the rail-wide gutters free so steppers / Done don't slide
            // under the chevrons. 32 = 28 rail + 4 breathing room. Vertical
            // inset keeps the header off the bezel and pulls the Done button
            // up from the very bottom.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              child: child,
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 28,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${setIndex + 1}/$totalSets',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _RailChevron(
                    icon: Icons.chevron_left,
                    enabled: prevEnabled,
                    onPressed: onPrev,
                    tooltip: 'Previous set',
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 28,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Always render the HR slot so the rail height doesn't
                  // jump when the sensor warms up. Greyed placeholder when
                  // we don't have a live sample.
                  Icon(
                    Icons.favorite,
                    size: 12,
                    color: heartRateBpm != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    heartRateBpm?.toString() ?? '—',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: heartRateBpm != null
                          ? null
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _RailChevron(
                    icon: Icons.chevron_right,
                    enabled: nextEnabled,
                    onPressed: onNext,
                    tooltip: 'Next set',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailChevron extends StatelessWidget {
  const _RailChevron({
    required this.icon,
    required this.enabled,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 18,
            color: enabled ? null : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }
}

/// Wraps a set view's main controls in a scrollable column with a small
/// "actions" tray below. The main region is sized to the viewport so the
/// existing space-between layout still works; the actions tray is reachable
/// with a small flick. New aux buttons (swap exercise, skip set, etc.) slot
/// into the tray without crowding the chord.
class _ScrollableSetView extends StatelessWidget {
  const _ScrollableSetView({
    required this.main,
    required this.onSwap,
  });

  final Widget main;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    final isRound = WatchShapeScope.of(context);
    final hInset = isRound ? 24.0 : 12.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: constraints.maxHeight, child: main),
              Padding(
                padding:
                    EdgeInsets.fromLTRB(hInset, 4, hInset, isRound ? 24 : 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onSwap,
                    icon: const Icon(Icons.swap_horiz, size: 16),
                    label: const Text('Swap exercise'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(32),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Compact name + optional "last time" caption header. Set counter sits on
/// the left rail; chevrons + HR sit on the side rails — kept off this header
/// so it stays short.
Widget _setHeader(
  BuildContext context, {
  required String exerciseName,
  String? lastTimeText,
}) {
  final theme = Theme.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        exerciseName,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      if (lastTimeText != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            lastTimeText,
            style: theme.textTheme.labelSmall?.copyWith(
              height: 1.0,
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
        ),
    ],
  );
}

Widget _doneButton({
  required BuildContext context,
  required bool completed,
  required VoidCallback onTap,
}) {
  final style = FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(32),
    padding: const EdgeInsets.symmetric(horizontal: 12),
  );
  // Pill button at the bottom of the round face — pull its ends inside the
  // bezel chord.
  final isRound = WatchShapeScope.of(context);
  final hInset = isRound ? 32.0 : 0.0;
  return Padding(
    padding: EdgeInsets.symmetric(horizontal: hInset),
    child: SizedBox(
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
    ),
  );
}

class _RestView extends StatelessWidget {
  const _RestView({
    required this.secondsLeft,
    required this.upNextName,
    required this.upNextTarget,
    required this.ambient,
    required this.onSkip,
    required this.onAdd15,
    required this.onSub15,
  });

  final int secondsLeft;
  final String? upNextName;
  final String? upNextTarget;
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
    // Skip button at the bottom — pull its ends inside the bezel on round.
    final isRound = WatchShapeScope.of(context);
    final skipInset = isRound ? 32.0 : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
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
          if (upNextName != null) ...[
            const SizedBox(height: 8),
            Text(
              'Up next: $upNextName',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (upNextTarget != null && upNextTarget != '—')
              Text(
                upNextTarget!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
          const Spacer(),
          if (!ambient)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: skipInset),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: onSkip,
                  child: const Text('Skip'),
                ),
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
    required this.onDiscard,
  });

  final List<_ExerciseListItem> exercises;
  final int currentExerciseIdx;
  final String routineName;
  final bool started;
  final bool allDone;
  final void Function(int eIdx) onPick;
  final VoidCallback onStart;
  final VoidCallback onFinish;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRound = WatchShapeScope.of(context);
    // Pull the title and action buttons in past the bezel chord on round
    // watches. The list rows themselves stay full-width so they don't lose
    // space to the bezel inset — round clipping clips letters at the rounded
    // corners, but the user can scroll to bring any row into the chord.
    final titleInset = isRound ? 24.0 : 0.0;
    final actionInset = isRound ? 32.0 : 0.0;
    final vGap = isRound ? 12.0 : 4.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: vGap),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: titleInset),
            child: Text(
              routineName,
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            // Single scrollable region: exercise rows followed by the
            // Start / Finish / Discard actions. User can see more rows at a
            // time because the actions no longer claim fixed bottom space;
            // they're reached by scrolling to the end of the list.
            child: ListView.builder(
              itemCount: exercises.length + 1,
              itemBuilder: (context, i) {
                if (i == exercises.length) {
                  return Padding(
                    padding: EdgeInsets.only(
                      top: 8,
                      left: actionInset,
                      right: actionInset,
                      bottom: isRound ? 24 : 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        started
                            ? FilledButton(
                                onPressed: allDone ? onFinish : null,
                                child: const Text('Finish'),
                              )
                            : FilledButton(
                                onPressed: onStart,
                                child: const Text('Start'),
                              ),
                        if (started)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: TextButton(
                              onPressed: onDiscard,
                              style: TextButton.styleFrom(
                                minimumSize: const Size.fromHeight(28),
                                padding: EdgeInsets.zero,
                                foregroundColor: theme.colorScheme.error,
                              ),
                              child: const Text('Discard'),
                            ),
                          ),
                      ],
                    ),
                  );
                }
                final ex = exercises[i];
                final tappable = ex.totalSets > 0;
                final isCurrent = i == currentExerciseIdx;
                return InkWell(
                  onTap: tappable ? () => onPick(i) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
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
        ],
      ),
    );
  }
}
