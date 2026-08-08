import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/drift_repositories.dart';
import 'package:gym_tracker/data/exercise_seeds.dart';
import 'package:gym_tracker/data/muscle_seeds.dart';

/// The starter library a new install gets, and the guards that keep it from
/// writing over — or reviving — a library the user has already curated.
void main() {
  late AppDatabase db;
  late DriftExerciseRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = DriftExerciseRepository(db);
  });
  tearDown(() => db.close());

  group('seed data', () {
    test('every muscle name resolves to a seeded muscle', () {
      // A misspelled muscle would tag nothing and fail silently at runtime:
      // setExerciseMuscles takes ids, and muscleSyncId happily derives one for
      // a name no muscle row has.
      final known = muscleSeeds.toSet();
      final unknown = <String>{};
      for (final s in exerciseSeeds) {
        unknown.addAll(s.muscles.where((m) => !known.contains(m)));
      }
      expect(unknown, isEmpty);
    });

    test('names are unique and non-empty', () {
      final names = exerciseSeeds.map((s) => s.name).toList();
      expect(names.toSet(), hasLength(names.length));
      expect(names.where((n) => n.trim().isEmpty), isEmpty);
    });

    test('kinds are the two the schema allows', () {
      final kinds = exerciseSeeds.map((s) => s.kind).toSet();
      expect(kinds.difference({exerciseKindReps, exerciseKindTime}), isEmpty);
    });

    test('no name has a doubled space or leading/trailing whitespace', () {
      final sloppy = exerciseSeeds
          .map((s) => s.name)
          .where((n) => n != n.trim() || n.contains('  '))
          .toList();
      expect(sloppy, isEmpty);
    });
  });

  group('seeding', () {
    test('fills a pristine library and tags muscles', () async {
      expect(await seedStarterExercises(exercises: repo), isTrue);

      final rows = await repo.watchExercises().first;
      expect(rows, hasLength(exerciseSeeds.length));

      final byName = {for (final r in rows) r.name: r};
      final plank = byName['Plank']!;
      expect(plank.kind, exerciseKindTime);
      final plankMuscles = await repo.musclesForExercise(plank.syncId);
      expect(plankMuscles.map((m) => m.name), ['Abs']);

      final squat = byName['Barbell back squat']!;
      expect(squat.kind, exerciseKindReps);
      final squatMuscles = await repo.musclesForExercise(squat.syncId);
      expect(squatMuscles.map((m) => m.name).toSet(), {'Quads', 'Glutes'});
    });

    test('is a no-op when the library already has an exercise', () async {
      await db.createExercise('Bench Press');
      expect(await seedStarterExercises(exercises: repo), isFalse);

      final rows = await repo.watchExercises().first;
      expect(rows.map((r) => r.name), ['Bench Press']);
    });

    test('a tombstone alone blocks seeding, so deletions stay deleted',
        () async {
      // The guard that matters. createExercise reconciles by name and revives
      // a tombstone rather than failing on the UNIQUE name, so seeding into a
      // pruned library would quietly bring back what the user removed.
      final ex = await db.createExercise('Plank', kind: exerciseKindTime);
      await db.deleteExercise(ex.syncId);
      expect(await repo.watchExercises().first, isEmpty); // nothing visible
      expect(await repo.hasAnyExercise(), isTrue); // but not pristine

      expect(await seedStarterExercises(exercises: repo), isFalse);
      expect(await repo.watchExercises().first, isEmpty);
    });

    test('running twice writes once', () async {
      expect(await seedStarterExercises(exercises: repo), isTrue);
      expect(await seedStarterExercises(exercises: repo), isFalse);
      expect(
        await repo.watchExercises().first,
        hasLength(exerciseSeeds.length),
      );
    });
  });
}
