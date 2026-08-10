import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/sync/health_upload_consent.dart';

/// Heart rate is health data, and signing in is a contract rather than consent
/// to store it on a server. These cover the rule that decides whether it may
/// leave the device, and the stripping that enforces it.
void main() {
  group('allowed', () {
    test('no consent means no upload', () {
      expect(
        healthUploadAllowed(consentUid: null, signedInUid: 'u1'),
        isFalse,
      );
    });

    test('consent from the signed-in account allows it', () {
      expect(
        healthUploadAllowed(consentUid: 'u1', signedInUid: 'u1'),
        isTrue,
      );
    });

    test("another account's consent does not carry over", () {
      // A shared install: u2 signing in must not inherit u1's decision.
      expect(
        healthUploadAllowed(consentUid: 'u1', signedInUid: 'u2'),
        isFalse,
      );
    });

    test('signed out is never allowed', () {
      expect(
        healthUploadAllowed(consentUid: 'u1', signedInUid: null),
        isFalse,
      );
    });
  });

  group('stripping', () {
    Map<String, Object?> workout() => {
          'syncId': 'w1',
          'version': 3,
          'startedAtMs': 1000,
          'heartRateSamples': [
            {'t': 1000, 'bpm': 120},
          ],
          'avgHeartRate': 118,
          'maxHeartRate': 160,
          'completions': [
            {'syncId': 'c1', 'actualReps': 8, 'avgHeartRate': 130,
              'maxHeartRate': 145},
          ],
        };

    test('every heart-rate field goes, at both levels', () {
      final out = stripHealthData(workout());

      expect(out.containsKey('heartRateSamples'), isFalse);
      expect(out.containsKey('avgHeartRate'), isFalse);
      expect(out.containsKey('maxHeartRate'), isFalse);
      final c = (out['completions'] as List).single as Map;
      expect(c.containsKey('avgHeartRate'), isFalse);
      expect(c.containsKey('maxHeartRate'), isFalse);
    });

    test('the rest of the workout is untouched', () {
      final out = stripHealthData(workout());

      expect(out['syncId'], 'w1');
      expect(out['version'], 3);
      expect(out['startedAtMs'], 1000);
      final c = (out['completions'] as List).single as Map;
      expect(c['syncId'], 'c1');
      expect(c['actualReps'], 8);
    });

    test('the input is not mutated', () {
      // The same payload is fanned out to every transport; stripping for
      // Firestore must not empty the copy heading for the watch.
      final original = workout();
      stripHealthData(original);

      expect(original['avgHeartRate'], 118);
      expect((original['heartRateSamples'] as List), hasLength(1));
    });

    test('a payload with no heart rate survives unchanged', () {
      final out = stripHealthData({'syncId': 'w1', 'completions': const []});

      expect(out['syncId'], 'w1');
      expect(out['completions'], isEmpty);
    });
  });

  group('store', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('a fresh install has no consent', () async {
      expect(await HealthUploadConsentStore(db).read(), isNull);
    });

    test('consent survives, and revoking clears it', () async {
      final store = HealthUploadConsentStore(db);

      await store.grant('u1');
      expect(await store.read(), 'u1');

      await store.revoke();
      expect(await store.read(), isNull);
    });
  });
}
