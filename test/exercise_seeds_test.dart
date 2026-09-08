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

    test('every id is a well-formed uuid', () {
      // The ids are hand-transcribed, most of them out of a device backup, and
      // a truncated or mistyped one is invisible on the page. Shape is the only
      // thing that catches it before a device seeds under a bad id.
      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      );
      final malformed =
          exerciseSeeds.where((s) => !uuid.hasMatch(s.id)).map((s) => s.name);
      expect(malformed, isEmpty);
    });

    test('ids are unique', () {
      // Two entries sharing an id would collapse to one row on seeding, and the
      // second name would be lost without any error.
      final ids = exerciseSeeds.map((s) => s.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
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

      final squat = byName['Back squat']!;
      expect(squat.kind, exerciseKindReps);
      final squatMuscles = await repo.musclesForExercise(squat.syncId);
      expect(squatMuscles.map((m) => m.name).toSet(), {'Quads', 'Glutes'});
    });

    test(
      'seeds every entry under its own id',
      () async {
        await seedStarterExercises(exercises: repo);

        final rows = await repo.watchExercises().first;
        final idByName = {for (final r in rows) r.name: r.syncId};
        final wrong = exerciseSeeds
            .where((s) => idByName[s.name] != s.id)
            .map((s) => s.name);
        expect(wrong, isEmpty);
      },
      // Fails today, deliberately, and was checked to fail rather than assumed
      // to. Every entry carries the id it should be seeded under, but
      // seedStarterExercises still goes through createExercise, which mints a
      // uuid of its own. Un-skip when the seed writes the ids: without this
      // assertion nothing notices that ExerciseSeed.id is read nowhere outside
      // these tests.
      skip: 'seeding does not use ExerciseSeed.id yet',
    );

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
