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
    for (final code in ['permission-denied', 'unauthenticated',
        'invalid-argument', 'not-found', 'failed-precondition']) {
      expect(isRetryableFirestoreFailure(err(code)), isFalse, reason: code);
    }
  });

  test('anything unrecognised is retried', () {
    // Including errors that are not Firestore's at all: a StateError from our
    // own cache-answered-read check has to keep the loop alive, since the very
    // next attempt may reach the server.
    expect(isRetryableFirestoreFailure(err('some-future-code')), isTrue);
    expect(isRetryableFirestoreFailure(StateError('cache')), isTrue);
  });

  test('backoff grows then holds, so a late recovery is picked up quickly', () {
    expect(firestoreRetryDelay(1), const Duration(seconds: 1));
    expect(firestoreRetryDelay(3), const Duration(seconds: 4));
    expect(firestoreRetryDelay(5), const Duration(seconds: 16));
    // Capped: a connection back after an hour must not wait another hour.
    expect(firestoreRetryDelay(20), const Duration(seconds: 30));
  });
}
