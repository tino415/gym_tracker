import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_backend.dart';
import 'firestore_transport.dart';
import 'sync_ownership.dart';
import 'sync_service.dart';

/// Thin wrapper over [FirebaseAuth]. Only ever exercised when the backend is
/// enabled — the account UI gates on [authBackendEnabledProvider], and every
/// method here calls FirebaseAuth, which throws unless [Firebase.initializeApp]
/// has run (guaranteed by [firebaseReadyProvider]).
class AuthService {
  FirebaseAuth get _auth => FirebaseAuth.instance;

  Future<void> signInWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<void> registerWithEmail(String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email, password: password);

  /// Web: a redirect flow against the Auth emulator's fake picker (no real
  /// OAuth client needed). Redirect — not popup — because hosting serves COOP
  /// `same-origin` for drift's OPFS cross-origin isolation, which severs a
  /// popup's `window.opener`. NOTE: the same isolation headers (COOP
  /// `same-origin` + COEP `require-corp`, both required for OPFS) currently also
  /// block this redirect's cross-origin auth flow in the browser, so Google
  /// web sign-in is not yet functional — see the epic notes. Kept wired for the
  /// production hosting/auth step.
  /// Android: deferred to the production Firebase project (real OAuth client +
  /// Play Services), so it throws here rather than reaching an unwired path.
  Future<void> signInWithGoogle() async {
    if (kIsWeb) {
      await _auth.signInWithRedirect(GoogleAuthProvider());
      return;
    }
    throw UnsupportedError(
      'Google sign-in on Android needs the production Firebase project.',
    );
  }

  Future<void> signOut() => _auth.signOut();
}

/// Whether the "Continue with Google" affordance is offered. Currently false on
/// every platform: Android Google needs the production OAuth client, and web
/// Google is blocked by the very COOP/COEP isolation headers drift's OPFS
/// storage requires (relaxing them drops drift to IndexedDB). [signInWithGoogle]
/// stays wired for when Google can coexist (production auth-domain setup, or
/// browsers that support nested dedicated workers). Email/password is the
/// active path meanwhile.
bool get googleSignInSupported => false;

/// True when this build has the Firestore backend compiled in. Gates the
/// account button and page so a plain phone/watch build shows no auth UI.
final authBackendEnabledProvider = Provider<bool>((_) => syncBackendEnabled);

final authServiceProvider = Provider<AuthService>((_) => AuthService());

/// Reactive current-user stream. Emits null (never touching [FirebaseAuth])
/// until Firebase is initialized and only when the backend is enabled.
final authStateProvider = StreamProvider<User?>((ref) {
  final ready = ref.watch(firebaseReadyProvider).valueOrNull ?? false;
  if (!ready) return Stream<User?>.value(null);
  return FirebaseAuth.instance.authStateChanges();
});

/// The reactive attach/detach binder — the heart of opt-in server sync.
///
/// Watched (fire-and-forget) from the app root on phone/web only. It listens to
/// [authStateProvider] and keeps at most one [FirestoreSyncTransport] attached
/// to the running [SyncService]. Whether it attaches depends on the persisted
/// sync *owner* of this install's local store (see [SyncOwnershipStore] /
/// [decideSyncOwnership]): the first account to sign in adopts the store and
/// syncs, the same account keeps syncing, but a *different* account leaves the
/// transport detached — sync paused — so this device never pushes the owner's
/// data into another account or pulls another account's data on top of it.
/// Signed out, nothing is attached, so the app makes zero Firestore calls.
/// The paused state is recoverable: the account page lets the user claim the
/// device for the current account (persist the new owner + invalidate this
/// provider so it re-attaches).
///
/// The body runs once; the attach state lives in closure locals for the app's
/// lifetime. The owner marker is read asynchronously and cached, so the
/// auth-listener callback awaits it before deciding — guarding the async gap
/// with a [currentUid] recheck so a superseded sign-in can't land a transport.
final firestoreSyncBinderProvider = Provider<void>((ref) {
  if (!syncBackendEnabled) return; // backend not compiled in; stay inert

  final svc = ref.read(syncServiceProvider);
  final store = ref.watch(syncOwnershipStoreProvider);
  // Read the persisted owner once; the auth callback awaits this.
  final ownerFuture = store.read();

  FirestoreSyncTransport? current;
  String? currentUid;

  Future<void> attachForUid(String uid) async {
    final owner = await ownerFuture;
    // A newer auth change may have won while we awaited the marker; if so, this
    // attach is stale — bail rather than land a transport for a past uid.
    if (currentUid != uid) return;

    final decision = decideSyncOwnership(owner, uid);
    if (!decision.attach) return; // a different account owns the store: paused
    if (decision.newOwner != null) await store.write(decision.newOwner!);
    if (currentUid != uid) return; // recheck after the (possible) write await

    final t = FirestoreSyncTransport(uid: uid);
    current = t;
    svc.addTransport(t); // pushOnAttach defaults true — backup + catch-up
  }

  ref.listen<AsyncValue<User?>>(authStateProvider, (prev, next) {
    final uid = next.valueOrNull?.uid;
    if (uid == currentUid) return; // no change (also ignores token refresh)

    // Detach the old transport (uid changed or signed out). removeTransport
    // mutates SyncService's collections synchronously before its first await.
    final old = current;
    current = null;
    currentUid = uid;
    if (old != null) unawaited(svc.removeTransport(old));

    if (uid != null) unawaited(attachForUid(uid));
  }, fireImmediately: true);

  ref.onDispose(() {
    final old = current;
    if (old != null) unawaited(svc.removeTransport(old));
  });
});
