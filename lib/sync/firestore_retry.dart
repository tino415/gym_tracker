import 'package:cloud_firestore/cloud_firestore.dart';

/// How many times a failure that is *usually* permanent still gets another go.
///
/// Two cases need it. A read issued right after sign-in can come back
/// `permission-denied` simply because the auth token has not reached the
/// backend yet, and the transport attaches and reads at exactly that moment. And
/// a failure that is not Firestore's at all — a Drift exception on the phone
/// path, say — cannot be classified here, so it gets a few tries rather than
/// either an infinite loop or an immediate surrender.
const _uncertainAttempts = 3;

/// A read that had to be answered by the server came back from the cache.
///
/// Its own type because it is the one failure here that is *known* transient:
/// it means the network was unreachable, which is the exact condition a retry
/// loop exists to outlive. Thrown as a plain error it would be unclassifiable
/// (see below), get the few uncertain attempts, and give up after seconds —
/// abandoning the caller precisely when it should keep waiting.
class ServerReadUnavailable implements Exception {
  const ServerReadUnavailable(this.what);

  /// What was being read, for the log.
  final String what;

  @override
  String toString() => 'ServerReadUnavailable: $what needs a server read, '
      'got the cache';
}

/// Whether retrying a failed call could still succeed on attempt [attempt].
///
/// Retry loops here run for the life of the process, so this is not cosmetic: a
/// rules mismatch or a wrong uid fails identically every time, and re-issuing a
/// whole-collection read every thirty seconds forever costs battery and quota to
/// learn nothing.
bool isRetryableFirestoreFailure(Object error, {int attempt = 1}) {
  // Offline. Nothing about it gets truer or falser with attempts, and the
  // caller has no other route back — so this one never gives up.
  if (error is ServerReadUnavailable) return true;

  // Not Firestore's, so nothing here can tell transient from fatal. A Drift
  // failure on the phone seed path is the realistic one, and it repeats
  // identically, so this must not become an unbounded loop.
  if (error is! FirebaseException) return attempt <= _uncertainAttempts;

  return switch (error.code) {
    // Often just the token catching up, sometimes genuinely wrong rules.
    'permission-denied' || 'unauthenticated' => attempt <= _uncertainAttempts,
    'invalid-argument' ||
    'not-found' ||
    'already-exists' ||
    'failed-precondition' ||
    'out-of-range' ||
    'unimplemented' =>
      false,
    _ => true,
  };
}

/// Backoff for those loops: grows, then holds. Capped rather than unbounded so
/// a connection that comes back after an hour is picked up in under a minute.
Duration firestoreRetryDelay(int attempt) {
  const cap = Duration(seconds: 30);
  // Clamped at 6 so the shift reaches 32s and the cap is the thing that
  // actually bounds it. Clamping lower would top out under the cap and leave
  // it dead code.
  final seconds = 1 << (attempt.clamp(1, 6) - 1);
  final d = Duration(seconds: seconds);
  return d > cap ? cap : d;
}
