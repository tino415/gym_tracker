import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/sync/sync_ownership.dart';

void main() {
  group('decideSyncOwnership', () {
    test('first sign-in (no owner) attaches and adopts the uid', () {
      final d = decideSyncOwnership(null, 'alice');
      expect(d.attach, isTrue);
      expect(d.newOwner, 'alice');
    });

    test('same account attaches without changing the owner', () {
      final d = decideSyncOwnership('alice', 'alice');
      expect(d.attach, isTrue);
      expect(d.newOwner, isNull);
    });

    test('different account does not attach and does not adopt', () {
      final d = decideSyncOwnership('alice', 'bob');
      expect(d.attach, isFalse);
      expect(d.newOwner, isNull);
    });
  });

  group('SyncOwnershipStore', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('reads null before anything is written', () async {
      expect(await SyncOwnershipStore(db).read(), isNull);
    });

    test('write then read round-trips the uid', () async {
      final store = SyncOwnershipStore(db);
      await store.write('alice');
      expect(await store.read(), 'alice');
    });

    test('write overwrites the previous owner', () async {
      final store = SyncOwnershipStore(db);
      await store.write('alice');
      await store.write('bob');
      expect(await store.read(), 'bob');
    });

    test('a persisted owner survives a fresh store over the same db '
        '(simulated restart) and makes a different account decide not to '
        'attach', () async {
      await SyncOwnershipStore(db).write('alice');
      // A new store instance over the same db models the next app launch.
      final owner = await SyncOwnershipStore(db).read();
      expect(owner, 'alice');
      expect(decideSyncOwnership(owner, 'bob').attach, isFalse);
    });
  });
}
