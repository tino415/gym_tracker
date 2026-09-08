import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/sync/firestore_transport.dart';
import 'package:gym_tracker/sync/sync_codec.dart';
import 'package:gym_tracker/sync/sync_transport.dart';

/// The workout side of the Firestore transport. Workouts used to be append-only
/// here (a `_knownWorkouts` set plus an existence read), which is exactly why an
/// edited workout could never reach the server. They are now version-LWW, so
/// these tests pin the two rules that replaced it: never clobber a strictly
/// newer server doc, and never write (or emit) content we already hold.
void main() {
  late FakeFirebaseFirestore fs;
  late FirestoreSyncTransport transport;

  setUp(() {
    fs = FakeFirebaseFirestore();
    transport = FirestoreSyncTransport(uid: 'u1', firestore: fs);
  });

  tearDown(() => transport.dispose());

  CollectionReferenceLike wcol() =>
      fs.collection('users').doc('u1').collection('workouts');

  Map<String, Object?> payload({
    required int version,
    String name = 'Push',
    String syncId = 'w1',
  }) => WorkoutDto(
        syncId: syncId,
        routineSyncId: null,
        routineName: name,
        startedAtMs: 1000,
        endedAtMs: 2000,
        version: version,
        exercises: const [],
        completions: const [],
      ).toJson();

  Future<void> push(Map<String, Object?> p) =>
      transport.send(type: workoutCompletedType, payload: p);

  test('a workout edit overwrites its doc (the append-only bug)', () async {
    await push(payload(version: 1));
    await push(payload(version: 2, name: 'Edited'));

    final doc = await wcol().doc('w1').get();
    expect(doc.data()!['version'], 2);
    expect(doc.data()!['routineName'], 'Edited');
  });

  test('pushing identical content twice writes once', () async {
    await push(payload(version: 1));
    // Mutate the doc behind the transport's back; an idempotent re-push must
    // not rewrite it, which is what proves the second push was a no-op.
    await wcol().doc('w1').update({'routineName': 'Untouched'});

    await push(payload(version: 1));

    final doc = await wcol().doc('w1').get();
    expect(doc.data()!['routineName'], 'Untouched');
  });

  test('a strictly older push does not clobber a newer server doc', () async {
    await push(payload(version: 5, name: 'Newer'));
    await push(payload(version: 3, name: 'Stale'));

    final doc = await wcol().doc('w1').get();
    expect(doc.data()!['version'], 5);
    expect(doc.data()!['routineName'], 'Newer');
  });

  test('a doc we just wrote is not echoed back as an inbound message',
      () async {
    transport.start();
    final seen = <SyncMessage>[];
    final sub = transport.messages.listen(seen.add);

    await push(payload(version: 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      seen.where((m) => m.type == workoutCompletedType),
      isEmpty,
      reason: 'our own write coming back would start an apply/relay round trip',
    );
    await sub.cancel();
  });

  test('a doc written by someone else is emitted', () async {
    transport.start();
    final seen = <SyncMessage>[];
    final sub = transport.messages.listen(seen.add);

    // A peer's write: straight to Firestore, not through the transport.
    await wcol().doc('w2').set(payload(version: 1, syncId: 'w2'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final workoutMsgs =
        seen.where((m) => m.type == workoutCompletedType).toList();
    expect(workoutMsgs, hasLength(1));
    expect(workoutMsgs.single.payload['syncId'], 'w2');
    await sub.cancel();
  });

  // The exercise library. A device that seeds and then signs in pushes every
  // row at version 1, on top of documents the account may have been editing
  // for a long time, so the push has to arbitrate rather than overwrite.
  group('exercise library', () {
    CollectionReferenceLike ecol() =>
        fs.collection('users').doc('u1').collection('exercises');

    Map<String, Object?> exercise({
      required int version,
      String syncId = 'e1',
      String name = 'Bench press',
      List<String> muscles = const ['muscle:chest'],
    }) => ExerciseDto(
          syncId: syncId,
          name: name,
          kind: 'reps',
          version: version,
          createdAtMs: 1000,
          muscleSyncIds: muscles,
        ).toJson();

    Future<void> pushExercises(List<Map<String, Object?>> rows) =>
        transport.send(
          type: exerciseBundleType,
          payload: {'exercises': rows},
        );

    /// Start the transport and let its first snapshot land. The guard takes its
    /// server state from that snapshot, so a push before it writes nothing.
    /// SyncService always calls start() before any send, so this is the
    /// ordinary path, not a test convenience.
    Future<void> connected() async {
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test('a push before the server has answered is held, then replayed',
        () async {
      // A sign-in with no network. Writing blind is what would let a freshly
      // seeded library at version 1 flatten an edited account, and dropping the
      // bundle would strand a user who never touches the app again, since every
      // other route back into a push needs an external trigger.
      await pushExercises([exercise(version: 1, name: 'Deferred')]);
      expect((await ecol().doc('e1').get()).exists, isFalse,
          reason: 'nothing may be written before the server has answered');

      await connected();
      final doc = await ecol().doc('e1').get();
      expect(doc.exists, isTrue, reason: 'the held bundle replays on connect');
      expect(doc.data()!['name'], 'Deferred');
    });

    test('a held push still loses to a newer server doc when it replays',
        () async {
      await ecol().doc('e1').set(exercise(version: 5, name: 'Server copy'));
      await pushExercises([exercise(version: 1, name: 'Local copy')]);

      await connected();
      final doc = await ecol().doc('e1').get();
      expect(doc.data()!['name'], 'Server copy');
      expect(doc.data()!['version'], 5);
    });

    test('a stale push does not clobber a newer server doc', () async {
      await connected();
      await ecol().doc('e1').set(exercise(version: 3, name: 'Renamed'));
      await pushExercises([exercise(version: 1, name: 'Bench press')]);

      final doc = await ecol().doc('e1').get();
      expect(doc.data()!['version'], 3);
      expect(doc.data()!['name'], 'Renamed');
    });

    test('an equal-or-newer push writes', () async {
      await connected();
      await ecol().doc('e1').set(exercise(version: 2, name: 'Old'));
      await pushExercises([exercise(version: 2, name: 'Edited')]);

      final doc = await ecol().doc('e1').get();
      expect(doc.data()!['name'], 'Edited');
    });

    test('pushing identical content twice writes once', () async {
      await connected();
      await pushExercises([exercise(version: 1)]);
      // Mutated behind the transport's back: an idempotent re-push must not
      // rewrite it, which is what proves the second push was a no-op.
      await ecol().doc('e1').update({'name': 'Untouched'});
      await pushExercises([exercise(version: 1)]);

      final doc = await ecol().doc('e1').get();
      expect(doc.data()!['name'], 'Untouched');
    });

    test('a removed doc clears the cached version, so version 1 pushes again',
        () async {
      await connected();
      await pushExercises([exercise(version: 4)]);
      await ecol().doc('e1').delete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Recreated from scratch elsewhere, so it legitimately starts over at 1.
      // A stale cached version of 4 would make it unpushable for the session.
      await pushExercises([exercise(version: 1, name: 'Recreated')]);
      final doc = await ecol().doc('e1').get();
      expect(doc.exists, isTrue);
      expect(doc.data()!['name'], 'Recreated');
    });

    test('an inbound doc is still emitted after the guard has taken its state',
        () async {
      // The guard fills itself from the same snapshot the listener emits from.
      // Taking state from it must not be mistaken for "already delivered": a
      // versions-only map cannot suppress an emit, but a content cache filled
      // the same way would, and the device would silently never apply the
      // account's library.
      await ecol().doc('e9').set(exercise(version: 1, syncId: 'e9'));
      transport.start();
      final seen = <SyncMessage>[];
      final sub = transport.messages.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final bundles = seen.where((m) => m.type == exerciseBundleType).toList();
      expect(bundles, isNotEmpty);
      final ids = bundles
          .expand((m) => ExerciseBundleMessage.fromPayload(m.payload).exercises)
          .map((e) => e.syncId);
      expect(ids, contains('e9'));
      await sub.cancel();
    });
  });
}

/// fake_cloud_firestore returns its own collection type; this alias keeps the
/// helper above readable without importing cloud_firestore just for the type.
typedef CollectionReferenceLike = dynamic;
