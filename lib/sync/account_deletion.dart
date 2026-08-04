import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Every collection stored under `users/{uid}`. Deletion has to name them: a
/// client cannot recursively delete a document tree, so anything added here
/// later must be added to this list too or it will survive account deletion.
const List<String> userDataCollections = <String>[
  'routines',
  'workouts',
  'exercises',
];

/// Deletes a user's server-side data and their Firebase Auth account — the
/// in-app deletion path Google Play requires of any app that lets users create
/// an account.
///
/// The order is load-bearing. `firestore.rules` grants access to
/// `users/{uid}/**` only while `request.auth.uid == uid`, so the data must go
/// **before** the Auth user; delete the account first and every remaining
/// document becomes unreachable, by this client or any other.
class AccountDeletionService {
  AccountDeletionService({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _firestoreOverride = firestore,
        _authOverride = auth;

  final FirebaseFirestore? _firestoreOverride;
  final FirebaseAuth? _authOverride;

  // Resolved lazily, as in [AuthService]. Reading `.instance` in the
  // constructor would throw without an initialised Firebase app, which would
  // couple the data-deletion tests to Auth they never touch.
  FirebaseFirestore get _fs => _firestoreOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// Firestore caps a write batch at 500 operations.
  static const _batchLimit = 500;

  /// Remove every document under `users/[uid]`, a batch at a time.
  ///
  /// Idempotent, which matters: if the account delete that follows fails, the
  /// user reauthenticates and retries, and this simply finds nothing left.
  Future<void> deleteUserData(String uid) async {
    final base = _fs.collection('users').doc(uid);
    for (final name in userDataCollections) {
      while (true) {
        final page = await base.collection(name).limit(_batchLimit).get();
        if (page.docs.isEmpty) break;
        final batch = _fs.batch();
        for (final doc in page.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        // A short page means that was the last one; a full page might not be.
        if (page.docs.length < _batchLimit) break;
      }
    }
  }

  /// Delete the signed-in user's data and then the account itself.
  ///
  /// Throws [FirebaseAuthException] with code `requires-recent-login` when the
  /// session is too old — callers reauthenticate *first* so that never strands
  /// a half-deleted account (see the account page).
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    await deleteUserData(user.uid);
    await user.delete();
  }
}

final accountDeletionServiceProvider = Provider<AccountDeletionService>(
  (ref) => AccountDeletionService(),
);
