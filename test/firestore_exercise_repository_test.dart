import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/firestore_repositories.dart';
import 'package:gym_tracker/data/muscle_seeds.dart';

void main() {
  late FakeFirebaseFirestore fs;
  late FirestoreExerciseRepository repo;

  setUp(() {
    fs = FakeFirebaseFirestore();
    repo = FirestoreExerciseRepository(uid: 'u1', firestore: fs);
  });

  group('createCatalogExercise', () {
    Future<Exercise?> seedOne({
      String syncId = 'seed-1',
      String name = 'Bench press',
    }) =>
        repo.createCatalogExercise(
          syncId: syncId,
          name: name,
          kind: exerciseKindReps,
          muscleSyncIds: [muscleSyncId('Chest')],
          createdAt: DateTime.utc(2026, 1, 1),
        );

    test('writes under the given id, at version 1, with its tags', () async {
      // Version 1 is the safety property: a fresh seed must always lose to an
      // account that has been edited, and it can only do that from the bottom.
      final ex = await seedOne();
      expect(ex, isNotNull);
      expect(ex!.syncId, 'seed-1');
      expect(ex.version, 1);

      final tags = await repo.musclesForExercise('seed-1');
      expect(tags.map((m) => m.name), ['Chest']);
    });

    test('a second install seeding the same entry writes no second doc',
        () async {
      await seedOne();
      final again = await seedOne();

      expect(again, isNotNull);
      final list = await repo.watchExercises().first;
      expect(list, hasLength(1), reason: 'same id means upsert, not duplicate');
    });

    test('returns null when a different doc already holds the name', () async {
      // Firestore has no UNIQUE(name), so nothing else would stop this. The
      // seed must not adopt a row under an id the catalogue does not own.
      await repo.createExercise('Bench press');
      final clash = await seedOne();

      expect(clash, isNull);
      final list = await repo.watchExercises().first;
      expect(list, hasLength(1));
      expect(list.single.syncId, isNot('seed-1'));
    });
  });

  test('createExercise persists and watchExercises emits it', () async {
    final ex = await repo.createExercise('Bench', kind: exerciseKindReps);
    expect(ex.name, 'Bench');
    expect(ex.version, 1);
    expect(ex.deletedAt, isNull);

    final list = await repo.watchExercises().first;
    expect(list.map((e) => e.name), ['Bench']);
    expect(list.single.syncId, ex.syncId);
  });

  test('watchExercises is sorted by name', () async {
    await repo.createExercise('Squat');
    await repo.createExercise('Bench');
    await repo.createExercise('Deadlift');
    final list = await repo.watchExercises().first;
    expect(list.map((e) => e.name), ['Bench', 'Deadlift', 'Squat']);
  });

  test('rename / setKind bump the version', () async {
    final ex = await repo.createExercise('Bench');
    await repo.renameExercise(ex.syncId, 'Incline Bench');
    await repo.setExerciseKind(ex.syncId, exerciseKindTime);

    final row = (await repo.watchExercises().first).single;
    expect(row.name, 'Incline Bench');
    expect(row.kind, exerciseKindTime);
    expect(row.version, greaterThan(1));
  });

  test('setExerciseMuscles resolves tags via the static registry', () async {
    final ex = await repo.createExercise('Bench');
    await repo.setExerciseMuscles(ex.syncId, [muscleSyncId('Chest')]);

    final withMuscles = (await repo.watchExercisesWithMuscles().first).single;
    expect(withMuscles.muscles.map((m) => m.name), ['Chest']);

    final direct = await repo.musclesForExercise(ex.syncId);
    expect(direct.map((m) => m.name), ['Chest']);
  });

  test('deleteExercise tombstones: hidden from library, doc survives', () async {
    final ex = await repo.createExercise('Bench');
    await repo.deleteExercise(ex.syncId);

    expect(await repo.watchExercises().first, isEmpty);
    final doc = await fs
        .collection('users')
        .doc('u1')
        .collection('exercises')
        .doc(ex.syncId)
        .get();
    expect(doc.exists, isTrue);
    expect(doc.data()!['deletedAtMs'], isNotNull);
  });

  test('re-creating a soft-deleted name revives the same doc', () async {
    final first = await repo.createExercise('Plank', kind: exerciseKindReps);
    await repo.deleteExercise(first.syncId);
    expect(await repo.watchExercises().first, isEmpty); // tombstoned, hidden

    // Recreating that name must not add a duplicate doc; it revives the
    // tombstone (same identity, cleared deletedAt, new kind, bumped version).
    final again = await repo.createExercise('Plank', kind: exerciseKindTime);
    expect(again.syncId, first.syncId);
    expect(again.deletedAt, isNull);
    expect(again.kind, exerciseKindTime);
    expect(again.version, greaterThan(first.version));

    // Exactly one doc for the name, and it's live in the library.
    final all = await fs
        .collection('users')
        .doc('u1')
        .collection('exercises')
        .where('name', isEqualTo: 'Plank')
        .get();
    expect(all.docs, hasLength(1));
    expect((await repo.watchExercises().first).map((e) => e.name), ['Plank']);
  });

  test('creating a name that is already live returns the existing doc', () async {
    final first = await repo.createExercise('Bench');
    final again = await repo.createExercise('Bench');
    expect(again.syncId, first.syncId);
    final all = await fs
        .collection('users')
        .doc('u1')
        .collection('exercises')
        .where('name', isEqualTo: 'Bench')
        .get();
    expect(all.docs, hasLength(1));
  });

  test('watchMuscles returns the static seed set', () async {
    final muscles = await repo.watchMuscles().first;
    expect(muscles.length, muscleSeeds.length);
    expect(muscles.map((m) => m.name), contains('Chest'));
  });
}
