import 'database.dart';
import 'repositories.dart';

/// Whether this build should insert demo routines on first launch. Off unless
/// built with `--dart-define=SEED_DEMO=true` (`just phone-apk-demo`), so a real
/// install can never pick it up.
const bool seedDemoEnabled = bool.fromEnvironment('SEED_DEMO');

/// Fills an empty install with routines that exercise the cases worth checking
/// by hand: reps sets, a circuit pair (alternation + per-member rest), and a
/// time-kind hold. Building these through the UI takes a couple of dozen taps
/// and is easy to get subtly wrong, which makes on-device verification far more
/// tedious than the thing being verified.
///
/// Bails out unless the library is completely empty, so it can't scribble over
/// real data if the define is left on by accident. Goes through the repository
/// seam, so it works the same on the Drift and Firestore backends.
Future<void> seedDemoData({
  required RoutineRepository routines,
  required ExerciseRepository exercises,
}) async {
  final existing = await routines.watchRoutineSummaries().first;
  if (existing.isNotEmpty) return;

  Future<String> exercise(String name, {String kind = exerciseKindReps}) async {
    final e = await exercises.createExercise(name, kind: kind);
    return e.syncId;
  }

  /// Adds [exerciseId] to [routineId] with [sets] identical target sets.
  Future<void> slot(
    String routineId,
    String exerciseId, {
    required int sets,
    int? reps,
    double? weightKg,
    int? seconds,
    int restSeconds = 90,
    int? circuitGroup,
  }) async {
    final re = await routines.addExerciseToRoutine(
      routineId: routineId,
      exerciseId: exerciseId,
    );
    await routines.setRestSeconds(re.syncId, restSeconds);
    if (circuitGroup != null) {
      await routines.setCircuitGroup(re.syncId, circuitGroup);
    }
    for (var i = 0; i < sets; i++) {
      await routines.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: reps,
        targetWeightKg: weightKg,
        targetSeconds: seconds,
      );
    }
  }

  final bench = await exercise('Bench Press');
  final fly = await exercise('Cable Fly');
  final pushdown = await exercise('Triceps Pushdown');
  final plank = await exercise('Plank', kind: exerciseKindTime);
  final legRaise = await exercise('Hanging Leg Raise');

  // A standalone exercise followed by a circuit pair — enough to see the
  // walker alternate between members. Rest 0 on the first member is what makes
  // it a classic superset: straight into the second, then a rest at the end of
  // the round, carried by the member that closes it.
  final push = await routines.createRoutine('Demo Push');
  await slot(push.syncId, bench, sets: 3, reps: 8, weightKg: 60);
  await slot(push.syncId, fly,
      sets: 3, reps: 12, weightKg: 15, circuitGroup: 1, restSeconds: 0);
  await slot(push.syncId, pushdown,
      sets: 3, reps: 12, weightKg: 25, circuitGroup: 1);

  // Short rests so the rest countdown can actually be watched to completion.
  final core = await routines.createRoutine('Demo Core');
  await slot(core.syncId, plank, sets: 3, seconds: 45, restSeconds: 30);
  await slot(core.syncId, legRaise, sets: 3, reps: 12, restSeconds: 30);
}
