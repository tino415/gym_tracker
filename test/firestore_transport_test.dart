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
}

/// fake_cloud_firestore returns its own collection type; this alias keeps the
/// helper above readable without importing cloud_firestore just for the type.
typedef CollectionReferenceLike = dynamic;
