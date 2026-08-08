import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/auth_service.dart';
import '../sync/firestore_backend.dart' show syncBackendEnabled;
import 'database.dart';
import 'demo_seed.dart';
import 'drift_repositories.dart';
import 'exercise_seeds.dart';
import 'firestore_repositories.dart';
import 'repositories.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// True on the server-backed **web** build: it reads/writes Firestore directly
/// (no local Drift DB). Phone/watch stay on Drift. Overridable in tests.
final firestoreDirectProvider = Provider<bool>(
  (_) => kIsWeb && syncBackendEnabled,
);

/// The signed-in uid, or null. A seam over [authStateProvider] so the
/// repository selection is testable without mocking a Firebase `User`. Used
/// only on the Firestore-direct web build, which is auth-gated so the
/// repositories are only read once this is non-null.
final currentUidProvider = Provider<String?>(
  (ref) => ref.watch(authStateProvider).valueOrNull?.uid,
);

final routineRepositoryProvider = Provider<RoutineRepository>((ref) {
  if (ref.watch(firestoreDirectProvider)) {
    final uid = ref.watch(currentUidProvider);
    if (uid != null) return FirestoreRoutineRepository(uid: uid);
    throw StateError('routineRepository read while signed out (web-direct)');
  }
  return DriftRoutineRepository(ref.watch(databaseProvider));
});

final exerciseRepositoryProvider = Provider<ExerciseRepository>((ref) {
  if (ref.watch(firestoreDirectProvider)) {
    final uid = ref.watch(currentUidProvider);
    if (uid != null) return FirestoreExerciseRepository(uid: uid);
    throw StateError('exerciseRepository read while signed out (web-direct)');
  }
  return DriftExerciseRepository(ref.watch(databaseProvider));
});

final workoutRepositoryProvider = Provider<WorkoutRepository>((ref) {
  if (ref.watch(firestoreDirectProvider)) {
    final uid = ref.watch(currentUidProvider);
    if (uid != null) return FirestoreWorkoutRepository(uid: uid);
    throw StateError('workoutRepository read while signed out (web-direct)');
  }
  return DriftWorkoutRepository(ref.watch(databaseProvider));
});

/// Runs the dev-only demo seed once per app start. A no-op unless the build
/// carries `--dart-define=SEED_DEMO=true`, and [seedDemoData] additionally
/// refuses to touch a store that already has routines.
final demoSeedProvider = FutureProvider<void>((ref) async {
  if (!seedDemoEnabled) return;
  await seedDemoData(
    routines: ref.read(routineRepositoryProvider),
    exercises: ref.read(exerciseRepositoryProvider),
  );
});

/// Fills a pristine library with the starter exercises. Unlike the demo seed
/// this ships in real builds, so it is guarded by [seedStarterExercises]'s
/// tombstone-aware check rather than a dart-define.
///
/// Self-gates on the uid: reading a repository while signed out throws on the
/// Firestore-direct web build. Because the provider watches the uid it re-runs
/// on sign-in, which is when a brand-new account's empty library appears.
final starterExerciseSeedProvider = FutureProvider<void>((ref) async {
  if (ref.watch(firestoreDirectProvider) &&
      ref.watch(currentUidProvider) == null) {
    return;
  }
  await seedStarterExercises(
    exercises: ref.read(exerciseRepositoryProvider),
  );
});

final exercisesStreamProvider = StreamProvider<List<Exercise>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchExercises();
});

final musclesStreamProvider = StreamProvider<List<Muscle>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchMuscles();
});

final exercisesWithMusclesStreamProvider =
    StreamProvider<List<ExerciseWithMuscles>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchExercisesWithMuscles();
});

final routineSummariesStreamProvider = StreamProvider<List<RoutineSummary>>((
  ref,
) {
  return ref.watch(routineRepositoryProvider).watchRoutineSummaries();
});

final fullRoutineProvider = StreamProvider.family<FullRoutine?, String>((
  ref,
  routineId,
) {
  return ref.watch(routineRepositoryProvider).watchFullRoutine(routineId);
});

final recentWorkoutsStreamProvider = StreamProvider<List<Workout>>((ref) {
  return ref.watch(workoutRepositoryProvider).watchRecentWorkouts();
});

final inProgressWorkoutStreamProvider = StreamProvider<Workout?>((ref) {
  return ref.watch(workoutRepositoryProvider).watchInProgressWorkout();
});

final fullWorkoutProvider = StreamProvider.family<FullWorkout?, String>((
  ref,
  workoutId,
) {
  return ref.watch(workoutRepositoryProvider).watchFullWorkout(workoutId);
});
