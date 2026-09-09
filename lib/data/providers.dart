import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/auth_service.dart';
import '../sync/firestore_backend.dart' show syncBackendEnabled;
import '../sync/firestore_retry.dart';
import '../sync/health_upload_consent.dart';
import 'database.dart';
import 'demo_seed.dart';
import 'drift_repositories.dart';
import 'exercise_seeds.dart';
import 'firestore_repositories.dart';
import 'repositories.dart';
import 'routine_name_repair.dart';

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
    if (uid != null) {
      return FirestoreWorkoutRepository(
        uid: uid,
        allowHealthUpload: () => healthUploadAllowed(
          consentUid: ref.read(healthUploadConsentProvider),
          signedInUid: uid,
        ),
      );
    }
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
/// Retried, because on the web the seed is a network write that fails closed.
/// It reads the server explicitly and aborts rather than write a catalogue over
/// a library it could not see, so a flaky connection at sign-up would otherwise
/// leave an empty library with nothing on screen to say so.
///
/// Retries until it works or the provider goes away, matching the transport's
/// guard rather than the "a restart will fix it" bound I first gave it. A
/// restart is not a thing that reliably happens: on web this is a PWA that can
/// stay open for days, this provider is not auto-dispose, and nothing else
/// triggers it. A few attempts over fifteen seconds is exactly the window a bad
/// connection outlives.
///
/// It stops early on a failure that cannot succeed — rules rejecting the read
/// reject it every time — so a misconfigured account does not re-read a whole
/// collection every half minute for as long as the tab is open.
final starterExerciseSeedProvider = FutureProvider<void>((ref) async {
  if (!seedStarterEnabled) return;
  if (ref.watch(firestoreDirectProvider) &&
      ref.watch(currentUidProvider) == null) {
    return;
  }
  var disposed = false;
  ref.onDispose(() => disposed = true);

  for (var attempt = 1; !disposed; attempt++) {
    try {
      await seedStarterExercises(exercises: ref.read(exerciseRepositoryProvider));
      return;
    } catch (e, st) {
      if (!isRetryableFirestoreFailure(e)) {
        // Loudly. Nothing renders this, and an empty library is the only other
        // symptom, so a silent swallow would leave no trace of why.
        debugPrint('starter seed failed permanently on attempt $attempt: $e\n$st');
        rethrow;
      }
      await Future<void>.delayed(firestoreRetryDelay(attempt));
    }
  }
});

/// One-off data migration: routines whose embedded exercise names predate the
/// rename fan-out. Web only — the Drift side joins by id and was never stale.
///
/// Guarded per account, so the collection scan happens once rather than on every
/// start (`routine_name_repair.dart`, which is deletable once every account has
/// been through it).
final routineNameRepairProvider = FutureProvider<void>((ref) async {
  if (!ref.watch(firestoreDirectProvider)) return;
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return;
  final routines = ref.read(routineRepositoryProvider);
  if (routines is! FirestoreRoutineRepository) return;
  await repairRoutineNamesOnce(uid: uid, routines: routines);
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
