import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
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

    /// Start the transport and let its listeners attach, as SyncService does
    /// before any send. The guard reads the server itself, so a push works
    /// without this; it is here so the listener-driven cases behave as they do
    /// in the app.
    Future<void> connected() async {
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test('an unreadable server holds the push back, then replays it', () async {
      // The case the guard exists for: a sign-in with no network. Writing blind
      // would let a freshly seeded library at version 1 flatten an edited
      // account; dropping the bundle would strand a user who never touches the
      // app again, since every other route into a push needs an external
      // trigger. So it must do neither.
      final t = _FailableReadTransport(uid: 'u1', firestore: fs);
      addTearDown(t.dispose);
      t.failReads = true;

      await t.send(
        type: exerciseBundleType,
        payload: {
          'exercises': [exercise(version: 1, name: 'Deferred')],
        },
      );
      expect((await ecol().doc('e1').get()).exists, isFalse,
          reason: 'nothing may be written while the server is unreachable');

      // Network back, and the retry the transport schedules for itself finds
      // it. Driven directly here rather than waiting 30s of wall clock.
      t.failReads = false;
      await t.retryGuard();

      final doc = await ecol().doc('e1').get();
      expect(doc.exists, isTrue, reason: 'the held bundle replays');
      expect(doc.data()!['name'], 'Deferred');
    });

    test('an offline stretch does not spend the budget for real failures',
        () async {
      // The budget exists for one thing: a permission-denied right after
      // sign-in is usually the auth token catching up, so it gets a few goes
      // before being called permanent. Cache-answered reads are not failures —
      // offline the SDK falls back without throwing — and charging them for
      // attempts let a few quiet minutes exhaust the budget, so the first real
      // permission-denied afterwards was judged permanent on sight, cancelling
      // the retry and stranding the held library for the life of the process.
      final t = _FailableReadTransport(uid: 'u1', firestore: fs);
      addTearDown(t.dispose);

      t.failReads = true;
      await t.send(
        type: exerciseBundleType,
        payload: {
          'exercises': [exercise(version: 1, name: 'Held')],
        },
      );
      expect(t.guardRetryArmed, isTrue, reason: 'a bundle is being held');

      // Offline for longer than the budget is deep.
      t.failReads = false;
      t.answerFromCache = true;
      for (var i = 0; i < 5; i++) {
        await t.runGuardRetryTick();
      }
      expect(t.guardRetryArmed, isTrue,
          reason: 'a non-answer must not end the retries');

      // Now the race the budget is for, on its first occurrence.
      t.answerFromCache = false;
      t.failReads = true;
      t.failureCode = 'permission-denied';
      await t.runGuardRetryTick();

      expect(t.guardRetryArmed, isTrue,
          reason: 'the first permission-denied is a race, not a verdict');

      // And it still recovers once the token lands.
      t.failReads = false;
      await t.retryGuard();
      expect((await ecol().doc('e1').get()).exists, isTrue,
          reason: 'the held bundle replays');
    });

    test('a push queued before dispose does not write after it', () async {
      // Pushes run one at a time, so a push accepted while the transport was
      // alive can reach the front of the queue long after it was disposed. That
      // is a sign-out or an account switch, and writing then puts one account's
      // library into whatever collection this transport still points at.
      final t = FirestoreSyncTransport(uid: 'u1', firestore: fs);
      t.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Issued, not awaited: both are queued while the transport is still live.
      unawaited(t.send(
        type: exerciseBundleType,
        payload: {'exercises': [exercise(version: 1)]},
      ));
      unawaited(t.send(
        type: exerciseBundleType,
        payload: {'exercises': [exercise(version: 1, syncId: 'e2', name: 'Squat')]},
      ));
      await t.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await ecol().get().then((s) => s.docs), isEmpty,
          reason: 'nothing may be written on behalf of a disposed transport');
    });

    test('an empty bundle does not displace a held one', () async {
      // The held payload is the only copy. A later empty bundle arriving while
      // the guard is still unloaded must not replace it, or the eventual replay
      // writes nothing and the library is lost for the session.
      final t = _FailableReadTransport(uid: 'u1', firestore: fs);
      addTearDown(t.dispose);
      t.failReads = true;

      await t.send(
        type: exerciseBundleType,
        payload: {
          'exercises': [exercise(version: 1, name: 'Real library')],
        },
      );
      await t.send(
        type: exerciseBundleType,
        payload: const {'exercises': <Map<String, Object?>>[]},
      );

      t.failReads = false;
      await t.retryGuard();

      final doc = await ecol().doc('e1').get();
      expect(doc.exists, isTrue, reason: 'the real bundle survived');
      expect(doc.data()!['name'], 'Real library');
    });

    test('a held push still loses to a newer server doc when it replays',
        () async {
      // Holding must not become a way to skip arbitration: the bundle waits,
      // and then loses on version exactly as it would have.
      await ecol().doc('e1').set(exercise(version: 5, name: 'Server copy'));
      final t = _FailableReadTransport(uid: 'u1', firestore: fs);
      addTearDown(t.dispose);
      t.failReads = true;

      await t.send(
        type: exerciseBundleType,
        payload: {
          'exercises': [exercise(version: 1, name: 'Local copy')],
        },
      );
      t.failReads = false;
      await t.retryGuard();

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

  // The phone pushes every routine the moment the transport attaches, on top
  // of documents the web or the assistant may have edited while the app was
  // closed, so the routine push has to arbitrate as the exercise push does.
  group('routines', () {
    CollectionReferenceLike rcol() =>
        fs.collection('users').doc('u1').collection('routines');

    Map<String, Object?> routine({
      required int version,
      String syncId = 'r1',
      String name = 'Walk',
    }) => RoutineTemplateDto(
          syncId: syncId,
          name: name,
          version: version,
          createdAtMs: 1000,
          exercises: const [],
        ).toJson();

    Future<void> pushRoutines(
      FirestoreSyncTransport t,
      List<Map<String, Object?>> rows,
    ) => t.send(type: routineBundleType, payload: {'routines': rows});

    Future<void> connected() async {
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    late _CommitCountingFirestore counted;

    setUp(() {
      counted = _CommitCountingFirestore();
      fs = counted;
      transport = FirestoreSyncTransport(uid: 'u1', firestore: fs);
    });

    /// Counted by commit, not by snapshot event: the fake's `snapshots()` drops
    /// a snapshot equal to the previous one, so an identical rewrite raises no
    /// event at all.
    Future<int> commitsDuring(Future<void> Function() action) async {
      final before = counted.commits;
      await action();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return counted.commits - before;
    }

    test('a stale push does not clobber a newer server doc', () async {
      await rcol().doc('r1').set(routine(version: 3, name: 'Edited elsewhere'));
      await connected();
      await pushRoutines(transport, [routine(version: 2, name: 'Phone copy')]);

      final doc = await rcol().doc('r1').get();
      expect(doc.data()!['version'], 3);
      expect(doc.data()!['name'], 'Edited elsewhere');
    });

    test('an unreadable server holds the push back, then replays it', () async {
      final t = _FailableReadTransport(uid: 'u1', firestore: fs);
      addTearDown(t.dispose);
      t.failRoutineReads = true;

      await pushRoutines(t, [routine(version: 1)]);
      expect((await rcol().doc('r1').get()).exists, isFalse,
          reason: 'nothing may be written while the server is unreadable');

      t.failRoutineReads = false;
      await t.retryGuard();

      expect((await rcol().doc('r1').get()).exists, isTrue,
          reason: 'the held bundle replays');
    });

    test('a held push still loses to a newer server doc when it replays',
        () async {
      await rcol().doc('r1').set(routine(version: 5, name: 'Server copy'));
      final t = _FailableReadTransport(uid: 'u1', firestore: fs);
      addTearDown(t.dispose);
      t.failRoutineReads = true;

      await pushRoutines(t, [routine(version: 1)]);
      t.failRoutineReads = false;
      await t.retryGuard();

      final doc = await rcol().doc('r1').get();
      expect(doc.data()!['version'], 5);
      expect(doc.data()!['name'], 'Server copy');
    });

    test('an equal-version push with different content writes', () async {
      await rcol().doc('r1').set(routine(version: 2, name: 'Old'));
      await connected();
      await pushRoutines(transport, [routine(version: 2, name: 'Edited')]);

      final doc = await rcol().doc('r1').get();
      expect(doc.data()!['name'], 'Edited');
    });

    test('a push identical to the server doc writes nothing', () async {
      await rcol().doc('r1').set(routine(version: 1));
      await connected();

      final commits = await commitsDuring(
        () => pushRoutines(transport, [routine(version: 1)]),
      );
      expect(commits, 0);
    });

    test('a routine seen from the server is not written back', () async {
      await connected();
      await rcol().doc('r1').set(routine(version: 3, name: 'Edited elsewhere'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final commits = await commitsDuring(
        () => pushRoutines(
          transport,
          [routine(version: 3, name: 'Edited elsewhere')],
        ),
      );
      expect(commits, 0);
    });
  });
}

/// fake_cloud_firestore returns its own collection type; this alias keeps the
/// helper above readable without importing cloud_firestore just for the type.
typedef CollectionReferenceLike = dynamic;

/// Lets a test decide whether the guard's server read succeeds. The fake routes
/// neither `mock_exceptions` nor its security rules through a collection `get`,
/// so an unreachable server cannot be simulated from outside, and that is the
/// only situation the guard's holding behaviour exists to handle.
class _FailableReadTransport extends FirestoreSyncTransport {
  _FailableReadTransport({required super.uid, super.firestore});

  bool failReads = false;

  /// Answer the read from the cache instead of failing it. Offline this is what
  /// the SDK actually does — it falls back without throwing — and the guard
  /// treats it as "learned nothing", not as an error.
  bool answerFromCache = false;

  /// The code the failing read reports, so a test can pick the class of
  /// failure it wants to exercise.
  String failureCode = 'unavailable';

  @override
  Future<QuerySnapshot<Map<String, Object?>>> readServerExercises() {
    if (answerFromCache) return Future.value(_CachedQuerySnapshot());
    if (failReads) {
      return Future.error(
        FirebaseException(plugin: 'cloud_firestore', code: failureCode),
      );
    }
    return super.readServerExercises();
  }

  bool failRoutineReads = false;

  @override
  Future<QuerySnapshot<Map<String, Object?>>> readServerRoutines() {
    if (failRoutineReads) {
      return Future.error(
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
      );
    }
    return super.readServerRoutines();
  }

  /// Drives exactly what the transport's own retry timer runs, without the
  /// 30 seconds of wall clock.
  ///
  /// The settle matters: a flush reached through the load is fired unawaited,
  /// because awaiting a batch commit that only resolves on reconnection would
  /// hang the send that triggered it.
  Future<void> retryGuard() async {
    // Twice, because the timer fires repeatedly and one tick can accomplish
    // nothing through no fault of its own: it joins whatever load is already in
    // flight, and if that one was started while the server was still
    // unreachable it fails and the tick ends. The next tick starts a fresh
    // read. In the app that costs 30 seconds; here it costs a line.
    for (var i = 0; i < 2; i++) {
      await runGuardRetryTick();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

class _CommitCountingFirestore extends FakeFirebaseFirestore {
  int commits = 0;

  @override
  WriteBatch batch() => _CountingBatch(super.batch(), () => commits++);
}

class _CountingBatch implements WriteBatch {
  _CountingBatch(this._inner, this._onCommit);

  final WriteBatch _inner;
  final void Function() _onCommit;

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) =>
      _inner.set(document, data, options);

  @override
  Future<void> commit() {
    _onCommit();
    return _inner.commit();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// An empty snapshot flagged as cache-served, which is what `Source.server`
/// returns while offline: the SDK falls back rather than throwing, so this is
/// a non-answer and not a failure. The interface is wide and the guard reads
/// two things off it, hence noSuchMethod for the rest.
class _CachedQuerySnapshot implements QuerySnapshot<Map<String, Object?>> {
  @override
  List<QueryDocumentSnapshot<Map<String, Object?>>> get docs => const [];

  @override
  SnapshotMetadata get metadata => _CacheMetadata();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _CacheMetadata implements SnapshotMetadata {
  @override
  bool get isFromCache => true;

  @override
  bool get hasPendingWrites => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
