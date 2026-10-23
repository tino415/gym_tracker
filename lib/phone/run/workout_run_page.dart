import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import '../../sync/health_connect_publisher.dart';
import '../../sync/workout_bridge.dart';
import '../settings/health_connect_controller.dart';
import '../../watch/set_target_format.dart';
import '../../watch/circuit_nav.dart';

/// Whether to offer the live-run entry points. The flow is phone-only: running
/// a workout at a desktop browser is noise, and the native rest countdown has
/// no web equivalent.
///
/// Gate on [kIsWeb], *not* `firestoreDirectProvider` — that provider is
/// `kIsWeb && syncBackendEnabled`, so it would wrongly show the flow in a web
/// build made without `SYNC_BACKEND=firestore`.
bool get runFlowAvailable => !kIsWeb;

/// Guided set-by-set execution of a routine on the phone — the counterpart to
/// [WatchRunPage]. Built directly against the repository seam rather than by
/// extracting a shared controller from the watch page, which is entangled with
/// Wear-only concerns (rotary input, heart-rate sensor, round-screen layout).
///
/// Either [routineId] (start a new workout) or [resumeWorkoutId] (pick up an
/// unfinished one) must be given.
class WorkoutRunPage extends ConsumerStatefulWidget {
  const WorkoutRunPage({super.key, this.routineId, this.resumeWorkoutId})
      : assert(routineId != null || resumeWorkoutId != null);

  final String? routineId;
  final String? resumeWorkoutId;

  @override
  ConsumerState<WorkoutRunPage> createState() => _WorkoutRunPageState();
}

enum _Phase { logSet, rest }

const _timeTargetStep = 5;

class _WorkoutRunPageState extends ConsumerState<WorkoutRunPage>
    with WidgetsBindingObserver {
  String? _workoutId;
  FullWorkout? _snapshot;
  StreamSubscription<FullWorkout?>? _snapshotSub;
  StreamSubscription<String>? _timerDoneSub;
  String? _startError;

  /// Only the *first* snapshot emission seeds the position and loads targets.
  /// Later emissions refresh the display only — reloading targets on every
  /// emission would let a concurrent sync write cancel a running rest timer.
  /// Same invariant as the watch run page; see CLAUDE.md.
  bool _initialLoadDone = false;

  int _exerciseIdx = 0;
  int _setIdx = 0;
  _Phase _phase = _Phase.logSet;

  int _reps = 0;
  double _weightKg = 0;

  int _timeStartTarget = 0;
  // A target changed on the run page outlives navigating away, so a hold
  // still running on that set logs its elapsed time against the right start.
  final Map<String, int> _timeTargetOverrides = {};
  int _timeRemaining = 0;
  DateTime? _timeEndTime;
  // A running hold belongs to its set rather than to the one on screen, so it
  // keeps counting while the user looks at other sets.
  String? _holdSetId;
  int _holdSecondsLeft = 0;
  bool _timeTargetBuzzed = false;

  int _restSecondsLeft = 0;
  DateTime? _restEndTime;

  /// Whether the native service accepted the countdown. When it didn't, the
  /// Dart side buzzes instead so the signal is never lost.
  bool _nativeTimerArmed = false;

  /// Set once finish/discard has stopped the service. Re-issuing `clearTimer`
  /// after that would `startService` a fresh, orphaned instance, so teardown
  /// checks this first — same guard as the watch run page.
  bool _serviceStopped = false;

  Timer? _timer;

  /// What was logged for this exercise/set last time, shown as a reference.
  /// The token guards against a slow response landing after the user has
  /// already moved on.
  SetCompletion? _lastCompletion;
  int _lastCompletionToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _snapshotSub?.cancel();
    _timerDoneSub?.cancel();
    // Leaving the page ends the session's foreground presence — the workout
    // itself persists and the Resume banner brings it back.
    if (!_serviceStopped) {
      unawaited(WorkoutBridge.instance.clearTimer());
      unawaited(WorkoutBridge.instance.stop());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The periodic ticker is frozen while backgrounded, but the wall-clock
    // anchor and the native countdown are not. Re-sync on resume — or complete
    // now if the anchor already passed (native already buzzed).
    if (state != AppLifecycleState.resumed) return;
    final now = clock.now();
    if (_phase == _Phase.rest && _restEndTime != null) {
      if (now.isAfter(_restEndTime!)) {
        _onRestElapsed();
      } else {
        _startUiTicker();
        _tickCountdown();
      }
    } else if (_holding) {
      _startUiTicker();
      _tickCountdown();
    }
  }

  // --- Start / resume -----------------------------------------------------

  Future<void> _begin() async {
    final repo = ref.read(workoutRepositoryProvider);
    String workoutId;
    try {
      if (widget.resumeWorkoutId != null) {
        workoutId = widget.resumeWorkoutId!;
      } else {
        final w = await repo.createWorkout(
          routineId: widget.routineId,
          startedAt: clock.now(),
        );
        workoutId = w.syncId;
      }
    } catch (e) {
      if (mounted) setState(() => _startError = '$e');
      return;
    }
    if (!mounted) return;

    _snapshotSub = repo.watchFullWorkout(workoutId).listen((snap) {
      if (!mounted || snap == null) return;
      setState(() {
        _snapshot = snap;
        if (_initialLoadDone) return;
        _initialLoadDone = true;
        final seed = _firstIncomplete(snap) ?? _firstNonEmpty(snap);
        if (seed != null) {
          _exerciseIdx = seed.eIdx;
          _setIdx = seed.sIdx;
        }
        _loadCurrentSetTargets();
      });
    });
    _timerDoneSub =
        WorkoutBridge.instance.timerDoneStream.listen(_onNativeTimerDone);
    setState(() => _workoutId = workoutId);

    // Foreground the process so the native countdown survives backgrounding.
    // No requestPermissions() here — that prompts for BODY_SENSORS, which the
    // phone has no use for.
    unawaited(WorkoutBridge.instance.start(routineName: _routineName()));
  }

  // --- Snapshot accessors -------------------------------------------------

  int _exerciseCount() => _snapshot?.exercises.length ?? 0;

  int _setCount(int eIdx) {
    final snap = _snapshot;
    if (snap == null || eIdx < 0 || eIdx >= snap.exercises.length) return 0;
    return snap.exercises[eIdx].sets.length;
  }

  int? _circuitGroupAt(int eIdx) {
    final snap = _snapshot;
    if (snap == null || eIdx < 0 || eIdx >= snap.exercises.length) return null;
    return snap.exercises[eIdx].workoutExercise.circuitGroup;
  }

  CircuitSeq get _seq => CircuitSeq(
        exerciseCount: _exerciseCount(),
        setCountAt: _setCount,
        circuitGroupAt: _circuitGroupAt,
      );

  bool _isCompletedAt(int eIdx, int sIdx) {
    final snap = _snapshot;
    if (snap == null || eIdx >= snap.exercises.length) return false;
    final sets = snap.exercises[eIdx].sets;
    if (sIdx >= sets.length) return false;
    return sets[sIdx].completion != null;
  }

  ({int eIdx, int sIdx})? _nextForCompletion() =>
      _seq.nextForCompletion(_exerciseIdx, _setIdx, _isCompletedAt);

  ({int eIdx, int sIdx})? _firstNonEmpty(FullWorkout snap) {
    for (var i = 0; i < snap.exercises.length; i++) {
      if (snap.exercises[i].sets.isNotEmpty) return (eIdx: i, sIdx: 0);
    }
    return null;
  }

  ({int eIdx, int sIdx})? _firstIncomplete(FullWorkout snap) {
    for (var i = 0; i < snap.exercises.length; i++) {
      final sets = snap.exercises[i].sets;
      for (var j = 0; j < sets.length; j++) {
        if (sets[j].completion == null) return (eIdx: i, sIdx: j);
      }
    }
    return null;
  }

  FullWorkoutExercise? get _currentExercise {
    final snap = _snapshot;
    if (snap == null || _exerciseIdx >= snap.exercises.length) return null;
    return snap.exercises[_exerciseIdx];
  }

  FullWorkoutSet? get _currentSet {
    final ex = _currentExercise;
    if (ex == null || _setIdx >= ex.sets.length) return null;
    return ex.sets[_setIdx];
  }

  String _currentKind() => _currentExercise?.kind ?? exerciseKindReps;

  bool get _currentIsCompleted => _currentSet?.completion != null;

  String _routineName() =>
      _snapshot?.workout.routineName ?? _snapshot?.routine?.name ??
      context.l10n.runWorkoutDefaultName;

  /// Rest comes from the exercise whose set was just completed — the same rule
  /// standalone and inside a circuit, where each member carries the pause to
  /// the next member and the last member carries the round rest. Anchoring on
  /// the completed exercise rather than the upcoming one also keeps the rest
  /// right after a skip-ahead, where the next position isn't the planned one.
  /// Mirrors the watch.
  int _currentRestSeconds() {
    final snap = _snapshot;
    if (snap == null || _exerciseIdx >= snap.exercises.length) return 0;
    return snap.exercises[_exerciseIdx].workoutExercise.restSeconds;
  }

  // --- Targets & last-time reference --------------------------------------

  void _loadCurrentSetTargets() {
    unawaited(_refreshLastCompletion());

    final set = _currentSet;
    if (set == null) return;
    final ws = set.workoutSet;
    final completion = set.completion;
    if (_currentKind() == exerciseKindTime) {
      _timeStartTarget =
          _timeTargetOverrides[ws.syncId] ?? ws.targetSeconds ?? 30;
      _timeRemaining = completion?.actualSeconds != null
          ? _timeStartTarget - completion!.actualSeconds!
          : _timeStartTarget;
      _weightKg = completion?.actualWeightKg ?? (ws.targetWeightKg ?? 0);
    } else {
      _reps = completion?.actualReps ?? (ws.targetReps ?? 10);
      _weightKg = completion?.actualWeightKg ?? (ws.targetWeightKg ?? 20);
    }
  }

  Future<void> _refreshLastCompletion() async {
    final workoutId = _workoutId;
    final ex = _currentExercise;
    final exerciseId = ex?.workoutExercise.exerciseId;
    final token = ++_lastCompletionToken;
    if (workoutId == null || exerciseId == null) {
      setState(() => _lastCompletion = null);
      return;
    }
    final r = await ref
        .read(workoutRepositoryProvider)
        .lastCompletionForExerciseAtSetIndex(
          exerciseId: exerciseId,
          setIndex: _setIdx,
          excludeWorkoutId: workoutId,
        );
    // A slower earlier request must not overwrite a newer answer.
    if (!mounted || token != _lastCompletionToken) return;
    setState(() => _lastCompletion = r);
  }

  void _goTo(int eIdx, int sIdx) {
    _endRest();
    setState(() {
      _exerciseIdx = eIdx;
      _setIdx = sIdx;
      _phase = _Phase.logSet;
      _restSecondsLeft = 0;
      _loadCurrentSetTargets();
    });
  }

  // --- Logging ------------------------------------------------------------

  Future<void> _toggleDone() async {
    final workoutId = _workoutId;
    final set = _currentSet;
    if (workoutId == null || set == null) return;
    final repo = ref.read(workoutRepositoryProvider);

    final existing = set.completion;
    if (existing != null) {
      await repo.deleteCompletion(existing.syncId);
      return;
    }

    final elapsed = (_timeStartTarget - _shownTimeRemaining).clamp(0, 1 << 30);
    // One countdown at a time: the rest that follows needs the native slot.
    _stopHold();
    if (_currentKind() == exerciseKindTime) {
      await repo.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: set.workoutSet.syncId,
        actualSeconds: elapsed,
        actualWeightKg: _weightKg > 0 ? _weightKg : null,
      );
    } else {
      await repo.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: set.workoutSet.syncId,
        actualReps: _reps,
        actualWeightKg: _weightKg,
      );
    }
    unawaited(HapticFeedback.heavyImpact());
    if (!mounted) return;

    final next = _nextForCompletion();
    if (next == null) return; // Everything logged — stay put so Finish is easy.

    // Every set is followed by its own exercise's rest, circuit member or not.
    // Zero skips the rest screen entirely rather than showing it for a tick —
    // that is how a classic superset (no pause between its members) is now
    // expressed, and `_startRest(0)` would flash a 1s countdown.
    final rest = _currentRestSeconds();
    if (rest == 0) {
      _goTo(next.eIdx, next.sIdx);
    } else {
      _startRest(rest);
    }
  }

  // --- Countdowns ---------------------------------------------------------

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
      }
    } else if (_holding) {
      // Runs past zero into overtime so a hold kept longer logs the extra
      // seconds (`_toggleDone` computes startTarget - remaining).
      final remaining =
          (_timeEndTime!.difference(now).inMilliseconds / 1000).ceil();
      setState(() => _holdSecondsLeft = remaining);
      if (remaining <= 0 && !_timeTargetBuzzed) {
        _timeTargetBuzzed = true;
        if (!_nativeTimerArmed) unawaited(HapticFeedback.mediumImpact());
      }
    }
  }

  void _onNativeTimerDone(String kind) {
    if (!mounted) return;
    if (kind == kTimerKindRest) {
      _onRestElapsed();
    } else if (kind == kTimerKindTime) {
      _timeTargetBuzzed = true;
    }
  }

  void _armNativeTimer(String kind, DateTime end, {bool schedule = true}) {
    if (!schedule) {
      _nativeTimerArmed = false;
      return;
    }
    _nativeTimerArmed = true; // optimistic; cleared if the call fails
    WorkoutBridge.instance
        .setTimer(kind: kind, endTimeMs: end.millisecondsSinceEpoch)
        .then((ok) {
      if (mounted && !ok) _nativeTimerArmed = false;
    });
  }

  void _clearNativeTimer() {
    _nativeTimerArmed = false;
    unawaited(WorkoutBridge.instance.clearTimer());
  }

  void _endRest() {
    if (_restEndTime == null) return;
    _restEndTime = null;
    _timer?.cancel();
    _clearNativeTimer();
  }

  void _startRest(int seconds) {
    _timer?.cancel();
    final end = clock.now().add(Duration(seconds: seconds));
    _restEndTime = end;
    setState(() {
      _phase = _Phase.rest;
      _restSecondsLeft = seconds;
    });
    // A zero-length rest has no future instant to schedule; the immediate tick
    // completes it.
    _armNativeTimer(kTimerKindRest, end, schedule: seconds > 0);
    _startUiTicker();
  }

  /// Single completion path for rest, idempotent so whichever of the Dart
  /// ticker / native event / resume reconciliation arrives first wins.
  void _onRestElapsed() {
    if (_phase != _Phase.rest || _restEndTime == null) return;
    _restEndTime = null;
    _timer?.cancel();
    if (!_nativeTimerArmed) unawaited(HapticFeedback.heavyImpact());
    _nativeTimerArmed = false;
    _advanceAfterRest();
  }

  void _skipRest() {
    _endRest();
    _advanceAfterRest();
  }

  void _bumpRest(int delta) {
    if (_restEndTime == null) return;
    final floor = clock.now().add(const Duration(seconds: 1));
    var end = _restEndTime!.add(Duration(seconds: delta));
    if (end.isBefore(floor)) end = floor;
    _restEndTime = end;
    setState(() {
      _restSecondsLeft =
          (end.difference(clock.now()).inMilliseconds / 1000).ceil();
    });
    _armNativeTimer(kTimerKindRest, end);
  }

  void _advanceAfterRest() {
    _restEndTime = null;
    final next = _nextForCompletion();
    if (next == null) {
      setState(() => _phase = _Phase.logSet);
      return;
    }
    setState(() {
      _exerciseIdx = next.eIdx;
      _setIdx = next.sIdx;
      _phase = _Phase.logSet;
      _restSecondsLeft = 0;
      _loadCurrentSetTargets();
    });
  }

  String get _locale => Localizations.localeOf(context).toString();

  bool get _holding => _timeEndTime != null;

  bool get _holdingHere =>
      _holding && _holdSetId == _currentSet?.workoutSet.syncId;

  int get _shownTimeRemaining =>
      _holdingHere ? _holdSecondsLeft : _timeRemaining;

  void _toggleTimeRun() {
    final setId = _currentSet?.workoutSet.syncId;
    if (setId == null) return;
    if (_holdingHere) {
      setState(() {
        _timeRemaining = _holdSecondsLeft;
        _stopHold();
      });
      return;
    }
    _stopHold();
    final end = clock.now().add(Duration(seconds: _timeRemaining));
    _timeEndTime = end;
    _holdSetId = setId;
    _holdSecondsLeft = _timeRemaining;
    _timeTargetBuzzed = false;
    setState(() {});
    _armNativeTimer(kTimerKindTime, end, schedule: _timeRemaining > 0);
    _startUiTicker();
  }

  void _changeTimeTarget(int delta) {
    final setId = _currentSet?.workoutSet.syncId;
    final target = _timeStartTarget + delta;
    if (setId == null || target < _timeTargetStep) return;
    setState(() {
      _timeStartTarget = target;
      _timeTargetOverrides[setId] = target;
      _timeRemaining += delta;
      if (_holdingHere) _shiftHold(delta);
    });
  }

  void _shiftHold(int delta) {
    final end = _timeEndTime!.add(Duration(seconds: delta));
    _timeEndTime = end;
    _holdSecondsLeft += delta;
    _timeTargetBuzzed = _holdSecondsLeft <= 0;
    if (_holdSecondsLeft > 0) {
      _armNativeTimer(kTimerKindTime, end);
    } else {
      _clearNativeTimer();
    }
  }

  void _stopHold() {
    if (!_holding) return;
    _timeEndTime = null;
    _holdSetId = null;
    _timer?.cancel();
    _clearNativeTimer();
  }

  void _showHoldSet() {
    final pos = _positionOfSet(_holdSetId);
    if (pos == null) {
      setState(_stopHold);
    } else {
      _goTo(pos.eIdx, pos.sIdx);
    }
  }

  ({int eIdx, int sIdx})? _positionOfSet(String? workoutSetId) {
    for (var e = 0; e < _exerciseCount(); e++) {
      final sets = _snapshot!.exercises[e].sets;
      for (var s = 0; s < sets.length; s++) {
        if (sets[s].workoutSet.syncId == workoutSetId) {
          return (eIdx: e, sIdx: s);
        }
      }
    }
    return null;
  }

  // --- Finish / discard ---------------------------------------------------

  int _remainingSetCount() {
    var n = 0;
    for (var e = 0; e < _exerciseCount(); e++) {
      for (var s = 0; s < _setCount(e); s++) {
        if (!_isCompletedAt(e, s)) n++;
      }
    }
    return n;
  }

  Future<void> _finish() async {
    final workoutId = _workoutId;
    final snap = _snapshot;
    if (workoutId == null || snap == null) return;
    final remaining = _remainingSetCount();
    if (remaining > 0) {
      final ok = await _confirm(
        title: context.l10n.runFinishTitle,
        body: context.l10n.runUnloggedSets(remaining),
        action: context.l10n.runFinish,
      );
      if (!ok || !mounted) return;
    }
    _endRest();
    _stopHold();
    await ref.read(workoutRepositoryProvider).updateWorkoutTimes(
          workoutId: workoutId,
          startedAt: snap.workout.startedAt,
          endedAt: clock.now(),
        );
    _stopService();
    // Publish to Health Connect when the user opted in. Best-effort and
    // unawaited: the workout is saved either way, and a health-store write must
    // not hold up leaving the run page.
    if (ref.read(healthConnectEnabledProvider)) {
      unawaited(ref.read(healthConnectPublisherProvider).publish(workoutId));
    }
    if (!mounted) return;
    context.go('/history/$workoutId');
  }

  Future<void> _discard() async {
    final workoutId = _workoutId;
    if (workoutId == null) return;
    final ok = await _confirm(
      title: context.l10n.runDiscardTitle,
      body: context.l10n.runDiscardBody,
      action: context.l10n.runDiscard,
      destructive: true,
    );
    if (!ok || !mounted) return;
    _endRest();
    _stopHold();
    await ref.read(workoutRepositoryProvider).deleteWorkout(workoutId);
    _stopService();
    if (!mounted) return;
    context.go('/routines');
  }

  void _stopService() {
    _serviceStopped = true;
    unawaited(WorkoutBridge.instance.stop());
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: destructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(action),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_startError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.runWorkoutDefaultName)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(context.l10n.runStartError('$_startError')),
          ),
        ),
      );
    }
    final snap = _snapshot;
    if (snap == null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.runWorkoutDefaultName)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_routineName()),
        actions: [
          TextButton(onPressed: _finish, child: Text(context.l10n.runFinish)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'discard') _discard();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'discard',
                child: Text(context.l10n.runDiscardMenu),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _phase == _Phase.rest ? _buildRest() : _buildLogSet(),
            ),
            const Divider(height: 1),
            SizedBox(height: 132, child: _buildOverview(snap)),
          ],
        ),
      ),
    );
  }

  Widget _buildLogSet() {
    final ex = _currentExercise;
    final set = _currentSet;
    if (ex == null || set == null) {
      return Center(child: Text(context.l10n.runNothingToDo));
    }
    final kind = ex.kind;
    final ws = set.workoutSet;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      children: [
        if (_holding && !_holdingHere) _buildHoldElsewhereChip(),
        Text(
          ex.workoutExercise.exerciseName,
          // Keyed so tests can tell the current-exercise heading apart from
          // the same name repeated in the overview strip.
          key: const Key('runExerciseName'),
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          _circuitGroupAt(_exerciseIdx) != null
              ? context.l10n.runSetOfTotalCircuit(_setIdx + 1, ex.sets.length)
              : context.l10n.runSetOfTotal(_setIdx + 1, ex.sets.length),
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 16),
        Text(
          context.l10n.runTarget(formatSetTarget(
            context,
            kind: kind,
            reps: ws.targetReps,
            weightKg: ws.targetWeightKg,
            seconds: ws.targetSeconds,
          )),
          style: theme.textTheme.bodyLarge,
        ),
        _buildLastTime(kind),
        const SizedBox(height: 24),
        if (kind == exerciseKindTime) ..._buildTimeControls() else
          ..._buildRepsControls(),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _toggleDone,
          icon: Icon(_currentIsCompleted ? Icons.undo : Icons.check),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
          ),
          label: Text(_currentIsCompleted ? context.l10n.runUndoSet : context.l10n.commonDone),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: _goPrev,
              icon: const Icon(Icons.chevron_left),
              label: Text(context.l10n.runPrevious),
            ),
            TextButton.icon(
              onPressed: _goNext,
              icon: const Icon(Icons.chevron_right),
              iconAlignment: IconAlignment.end,
              label: Text(context.l10n.runNext),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHoldElsewhereChip() {
    final pos = _positionOfSet(_holdSetId);
    final name = pos == null
        ? context.l10n.runTimerChip
        : context.l10n.runExerciseTimer(
            _snapshot!.exercises[pos.eIdx].workoutExercise.exerciseName,
          );
    return Align(
      alignment: Alignment.centerLeft,
      child: ActionChip(
        avatar: const Icon(Icons.timer_outlined),
        label: Text('$name ${_formatSeconds(_holdSecondsLeft)}'),
        onPressed: _showHoldSet,
      ),
    );
  }

  Widget _buildLastTime(String kind) {
    final last = _lastCompletion;
    if (last == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        context.l10n.runLastTime(formatSetTarget(
          context,
          kind: kind,
          reps: last.actualReps,
          weightKg: last.actualWeightKg,
          seconds: last.actualSeconds,
        )),
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.outline),
      ),
    );
  }

  List<Widget> _buildRepsControls() => [
        _Stepper(
          label: context.l10n.commonReps,
          value: '$_reps',
          onMinus: _reps > 0 ? () => setState(() => _reps--) : null,
          onPlus: () => setState(() => _reps++),
        ),
        const SizedBox(height: 12),
        _Stepper(
          label: context.l10n.commonWeight,
          value: context.l10n.commonWeightKg(
            formatWeight(_weightKg, locale: _locale),
          ),
          onMinus: _weightKg >= 2.5
              ? () => setState(() => _weightKg -= 2.5)
              : null,
          onPlus: () => setState(() => _weightKg += 2.5),
        ),
      ];

  List<Widget> _buildTimeControls() => [
        Center(
          child: Text(
            _formatSeconds(_shownTimeRemaining),
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: _shownTimeRemaining < 0
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: OutlinedButton.icon(
            onPressed: _toggleTimeRun,
            icon: Icon(_holdingHere ? Icons.pause : Icons.play_arrow),
            label: Text(_holdingHere ? context.l10n.runPause : context.l10n.runStartTimer),
          ),
        ),
        const SizedBox(height: 12),
        _Stepper(
          label: context.l10n.commonTime,
          value: _formatSeconds(_timeStartTarget),
          onMinus: _timeStartTarget > _timeTargetStep
              ? () => _changeTimeTarget(-_timeTargetStep)
              : null,
          onPlus: () => _changeTimeTarget(_timeTargetStep),
        ),
        const SizedBox(height: 12),
        _Stepper(
          label: context.l10n.commonWeight,
          value: context.l10n.commonWeightKg(
            formatWeight(_weightKg, locale: _locale),
          ),
          onMinus: _weightKg >= 2.5
              ? () => setState(() => _weightKg -= 2.5)
              : null,
          onPlus: () => setState(() => _weightKg += 2.5),
        ),
      ];

  Widget _buildRest() {
    final theme = Theme.of(context);
    final next = _nextForCompletion();
    String upNext = '';
    if (next != null) {
      final snap = _snapshot!;
      final ex = snap.exercises[next.eIdx];
      final ws = ex.sets[next.sIdx].workoutSet;
      upNext = context.l10n.runUpNextLine(
        ex.workoutExercise.exerciseName,
        next.sIdx + 1,
        formatSetTarget(
          context,
          kind: ex.kind,
          reps: ws.targetReps,
          weightKg: ws.targetWeightKg,
          seconds: ws.targetSeconds,
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(context.l10n.runRest, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            _formatSeconds(_restSecondsLeft),
            style: theme.textTheme.displayLarge?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          if (upNext.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                context.l10n.runUpNext(upNext),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => _bumpRest(-15),
                child: Text(context.l10n.runRestMinus),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => _bumpRest(15),
                child: Text(context.l10n.runRestPlus),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _skipRest, child: Text(context.l10n.runSkipRest)),
        ],
      ),
    );
  }

  /// Horizontal strip of every set in the workout, so the user can see progress
  /// and jump anywhere.
  Widget _buildOverview(FullWorkout snap) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: snap.exercises.length,
      itemBuilder: (context, e) {
        final ex = snap.exercises[e];
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 160,
                child: Text(
                  ex.workoutExercise.exerciseName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (var s = 0; s < ex.sets.length; s++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _SetChip(
                        index: s + 1,
                        done: ex.sets[s].completion != null,
                        current: e == _exerciseIdx && s == _setIdx,
                        onTap: () => _goTo(e, s),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _goPrev() {
    final pos = _seq.prevBefore(_exerciseIdx, _setIdx);
    if (pos != null) _goTo(pos.eIdx, pos.sIdx);
  }

  void _goNext() {
    final pos = _seq.nextAfter(_exerciseIdx, _setIdx);
    if (pos != null) _goTo(pos.eIdx, pos.sIdx);
  }

  static String _formatSeconds(int total) {
    final neg = total < 0;
    final v = total.abs();
    final m = v ~/ 60;
    final s = v % 60;
    return '${neg ? '-' : ''}$m:${s.toString().padLeft(2, '0')}';
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(width: 72, child: Text(label, style: theme.textTheme.bodyLarge)),
        IconButton.outlined(
          onPressed: onMinus,
          icon: const Icon(Icons.remove),
          tooltip: context.l10n.runDecrease(label),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        IconButton.outlined(
          onPressed: onPlus,
          icon: const Icon(Icons.add),
          tooltip: context.l10n.runIncrease(label),
        ),
      ],
    );
  }
}

class _SetChip extends StatelessWidget {
  const _SetChip({
    required this.index,
    required this.done,
    required this.current,
    required this.onTap,
  });

  final int index;
  final bool done;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = done
        ? scheme.primary
        : current
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest;
    final fg = done
        ? scheme.onPrimary
        : current
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: current ? Border.all(color: scheme.primary, width: 2) : null,
        ),
        child: done
            ? Icon(Icons.check, size: 18, color: fg)
            : Text('$index', style: TextStyle(color: fg)),
      ),
    );
  }
}
