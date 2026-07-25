import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/drift_repositories.dart';
import 'package:gym_tracker/data/providers.dart';

void main() {
  test('firestoreDirect=false selects the Drift repositories', () {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = ProviderContainer(
      overrides: [
        firestoreDirectProvider.overrideWithValue(false),
        databaseProvider.overrideWithValue(db),
      ],
    );
    addTearDown(c.dispose);

    expect(c.read(routineRepositoryProvider), isA<DriftRoutineRepository>());
    expect(c.read(exerciseRepositoryProvider), isA<DriftExerciseRepository>());
    expect(c.read(workoutRepositoryProvider), isA<DriftWorkoutRepository>());
  });

  test('firestoreDirect=true while signed out throws (app gates on auth)', () {
    final c = ProviderContainer(
      overrides: [
        firestoreDirectProvider.overrideWithValue(true),
        currentUidProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);

    expect(() => c.read(routineRepositoryProvider), throwsStateError);
    expect(() => c.read(exerciseRepositoryProvider), throwsStateError);
    expect(() => c.read(workoutRepositoryProvider), throwsStateError);
  });
}
