import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/sync/firestore_retry.dart';

/// Which failures are worth trying again.
///
/// Two loops depend on this and both run for the life of the process: the
/// exercise push guard re-reads the collection on a timer while a bundle waits,
/// and the starter seed retries until it succeeds. Getting this wrong is cheap
/// in one direction and expensive in the other, which is why unrecognised
/// errors are retryable: giving up on a transient failure strands data, while
/// giving up late on a permanent one wastes a few reads.
void main() {
  FirebaseException err(String code) =>
      FirebaseException(plugin: 'cloud_firestore', code: code);

  test('a connection that might come back is retried', () {
    for (final code in ['unavailable', 'deadline-exceeded', 'aborted',
        'internal', 'resource-exhausted', 'cancelled']) {
      expect(isRetryableFirestoreFailure(err(code)), isTrue, reason: code);
    }
  });

  test('a failure that will repeat identically is not', () {
    // Rules rejecting a read reject it every time. Retrying costs battery and
    // quota to learn nothing, and on web it would run for as long as the tab.
    for (final code in ['invalid-argument', 'not-found', 'already-exists',
        'failed-precondition', 'out-of-range', 'unimplemented']) {
      expect(isRetryableFirestoreFailure(err(code)), isFalse, reason: code);
    }
  });

  test('an auth rejection gets a few goes, then stops', () {
    // The transport attaches and reads the instant the user signs in, which is
    // exactly when the token may not have reached the backend yet, so the first
    // permission-denied is as likely to be a race as a misconfiguration. It is
    // still usually a misconfiguration, so this must not become a forever loop.
    for (final code in ['permission-denied', 'unauthenticated']) {
      expect(isRetryableFirestoreFailure(err(code), attempt: 1), isTrue,
          reason: code);
      expect(isRetryableFirestoreFailure(err(code), attempt: 3), isTrue,
          reason: code);
      expect(isRetryableFirestoreFailure(err(code), attempt: 4), isFalse,
          reason: code);
    }
  });

  test('an unrecognised Firestore code is retried indefinitely', () {
    expect(isRetryableFirestoreFailure(err('some-future-code')), isTrue);
    expect(
      isRetryableFirestoreFailure(err('some-future-code'), attempt: 99),
      isTrue,
    );
  });

  test('an unreachable server is retried for as long as it takes', () {
    // The seed's own abort when a Source.server read is answered from the
    // cache. It is the one failure here that is known transient, and it has
    // its own type for exactly that reason: as a plain error it fell into the
    // clause below, gave up after about seven seconds, and left the account
    // with an empty library for the life of the tab.
    const offline = ServerReadUnavailable('catalogue seed');
    expect(isRetryableFirestoreFailure(offline), isTrue);
    expect(isRetryableFirestoreFailure(offline, attempt: 99), isTrue);
  });

  test('a non-Firestore failure is retried, but not forever', () {
    // Nothing here can classify one. The realistic case is the phone seed path,
    // where the repository is Drift and the error is a SqliteException that will
    // repeat identically — an unbounded loop there re-runs a whole transaction
    // every thirty seconds for the life of the process.
    expect(isRetryableFirestoreFailure(StateError('cache'), attempt: 1), isTrue);
    expect(isRetryableFirestoreFailure(StateError('cache'), attempt: 4), isFalse);
  });

  test('backoff grows then holds, so a late recovery is picked up quickly', () {
    expect(firestoreRetryDelay(1), const Duration(seconds: 1));
    expect(firestoreRetryDelay(3), const Duration(seconds: 4));
    expect(firestoreRetryDelay(5), const Duration(seconds: 16));
    // Capped: a connection back after an hour must not wait another hour.
    expect(firestoreRetryDelay(20), const Duration(seconds: 30));
  });
}
