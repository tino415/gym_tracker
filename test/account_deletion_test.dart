import 'package:cloud_firestore/cloud_firestore.dart' show CollectionReference;
import 'package:drift/native.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/sync/account_deletion.dart';
import 'package:gym_tracker/sync/sync_ownership.dart';

/// Deleting an account has to actually remove the data. The rules only grant
/// access to `users/{uid}/**` while that user is signed in, so anything missed
/// here is unreachable afterwards — by this client or any other.
void main() {
  group('server data', () {
    late FakeFirebaseFirestore fs;
    late AccountDeletionService service;

    setUp(() {
      fs = FakeFirebaseFirestore();
      service = AccountDeletionService(firestore: fs);
    });

    CollectionReference<Map<String, dynamic>> col(String uid, String name) =>
        fs.collection('users').doc(uid).collection(name);

    Future<void> seed(String uid, {int perCollection = 3}) async {
      for (final name in userDataCollections) {
        for (var i = 0; i < perCollection; i++) {
          await col(uid, name).doc('$name-$i').set({'syncId': '$name-$i'});
        }
      }
    }

    test('removes every collection under the user', () async {
      await seed('u1');

      await service.deleteUserData('u1');

      for (final name in userDataCollections) {
        expect(
          (await col('u1', name).get()).docs,
          isEmpty,
          reason: '$name should have been deleted',
        );
      }
    });

    test('leaves other accounts alone', () async {
      await seed('u1');
      await seed('u2');

      await service.deleteUserData('u1');

      for (final name in userDataCollections) {
        expect((await col('u2', name).get()).docs, hasLength(3));
      }
    });

    test('is idempotent, so a retry after a failed delete is safe', () async {
      await seed('u1');

      await service.deleteUserData('u1');
      await service.deleteUserData('u1');

      for (final name in userDataCollections) {
        expect((await col('u1', name).get()).docs, isEmpty);
      }
    });

    test('deletes past a single batch', () async {
      // The batch limit is 500; more than that must not be silently left
      // behind by a single pass.
      for (var i = 0; i < 620; i++) {
        await col('u1', 'workouts').doc('w$i').set({'syncId': 'w$i'});
      }

      await service.deleteUserData('u1');

      expect((await col('u1', 'workouts').get()).docs, isEmpty);
    });

    test('the collection list covers what the repositories write', () {
      // A collection added later but not listed here would survive deletion,
      // which is the failure this whole file exists to prevent.
      expect(
        userDataCollections,
        containsAll(<String>['routines', 'workouts', 'exercises']),
      );
    });
  });

  group('local cleanup', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('clearAllLocalData empties every table', () async {
      final routine = await db.createRoutine('Push');
      final ex = await db.createExercise('Bench');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(routineExerciseId: re.syncId, targetReps: 8);
      final w = await db.startWorkout(routine.syncId);
      await db.setSyncMeta('owner_uid', 'u1');

      await db.clearAllLocalData();

      expect(await db.watchRoutineSummaries().first, isEmpty);
      expect(await db.watchRecentWorkouts().first, isEmpty);
      expect(await db.watchExercises().first, isEmpty);
      expect(await db.loadFullWorkout(w.syncId), isNull);
      expect(await db.getSyncMeta('owner_uid'), isNull);
    });

    test('the owner marker can be cleared without wiping the data', () async {
      final store = SyncOwnershipStore(db);
      await db.createRoutine('Push');
      await store.write('u1');

      await store.clear();

      // Deleting an account must not strand a dead uid here: a later sign-in
      // would never match it and would sit with sync paused forever.
      expect(await store.read(), isNull);
      expect(await db.watchRoutineSummaries().first, hasLength(1));
    });

    test('a cleared marker means the next account adopts the install', () async {
      final store = SyncOwnershipStore(db);
      await store.write('deleted-uid');
      await store.clear();

      final decision = decideSyncOwnership(await store.read(), 'new-uid');

      expect(decision.attach, isTrue);
      expect(decision.newOwner, 'new-uid');
    });
  });
}
