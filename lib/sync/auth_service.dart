import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'firestore_backend.dart';
import 'firestore_transport.dart';
import 'sync_ownership.dart';
import 'sync_service.dart';

/// Thin wrapper over [FirebaseAuth]. Only ever exercised when the backend is
/// enabled — the account UI gates on [authBackendEnabledProvider], and every
/// method here calls FirebaseAuth, which throws unless [Firebase.initializeApp]
/// has run (guaranteed by [firebaseReadyProvider]).
/// The `gym-tracker-44a5f` project's OAuth 2.0 **Web** client ID
/// (`client_type: 3`). Passed to google_sign_in as `serverClientId` on Android
/// so the Google ID token it returns carries an audience Firebase Auth accepts.
/// Like the web [FirebaseOptions] in `firestore_backend.dart`, this is a public
/// client identifier (it ships in the web bundle / APK) — access is gated by
/// Firebase Auth + Firestore rules, not by keeping it secret — so it's baked in
/// as the default rather than requiring a `--dart-define` on every build. The
/// `GOOGLE_SERVER_CLIENT_ID` override exists only for pointing a build at a
/// different project. (Web doesn't read this — its popup flow knows the client
/// internally; the const is only consumed on the Android path.)
const String _googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue:
      '15728358407-ib0tqktaurck8fr0l6fpsqv6312l8v19.apps.googleusercontent.com',
);

class AuthService {
  FirebaseAuth get _auth => FirebaseAuth.instance;

  /// google_sign_in v7 requires a single `initialize` before the first
  /// `authenticate`. Guarded so repeated sign-in attempts don't re-init.
  bool _googleInitialized = false;

  Future<void> signInWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<void> registerWithEmail(String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email, password: password);

  /// Web: a popup flow. Popup — not redirect — because the caller awaits this
  /// (see the account/sign-in `_run` wrappers); a redirect reloads the page
  /// mid-await instead of resolving. Popups are viable again now that the web
  /// build is Firestore-direct: it needs no OPFS, so hosting no longer serves
  /// the COOP `same-origin` / COEP `require-corp` isolation headers that used
  /// to sever `window.opener` and block the cross-origin auth flow. Requires
  /// the Google provider to be enabled in the Firebase Auth console (the
  /// `.web.app` / `.firebaseapp.com` domains are authorized by default).
  /// Android: the native google_sign_in v7 Credential Manager flow, whose
  /// Google ID token is exchanged for a Firebase credential. Requires the app's
  /// package + signing SHA-1 to be registered as an Android OAuth client in the
  /// `gym-tracker-44a5f` project, the Google provider enabled in Firebase Auth,
  /// and [_googleServerClientId] baked into the build. A user-cancelled picker
  /// is swallowed (returns normally) rather than surfaced as an error.
  Future<void> signInWithGoogle() async {
    if (kIsWeb) {
      await _auth.signInWithPopup(GoogleAuthProvider());
      return;
    }
    if (_googleServerClientId.isEmpty) {
      throw StateError(
        'GOOGLE_SERVER_CLIENT_ID not set in this build — cannot start the '
        'Android Google sign-in flow.',
      );
    }
    final google = GoogleSignIn.instance;
    if (!_googleInitialized) {
      await google.initialize(serverClientId: _googleServerClientId);
      _googleInitialized = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await google.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return; // user aborted
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw FirebaseAuthException(
        code: 'missing-google-id-token',
        message: 'Google sign-in returned no ID token.',
      );
    }
    await _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  Future<void> signOut() => _auth.signOut();
}

/// Whether the "Continue with Google" affordance is offered.
///
/// Web: always — the Firestore-direct web build drops OPFS, so hosting no
/// longer sets the COOP/COEP isolation headers that used to break the popup
/// auth flow, and [signInWithGoogle] runs a real popup against the prod project.
///
/// Android: only when [_googleServerClientId] is baked into the build (a
/// `--dart-define=GOOGLE_SERVER_CLIENT_ID=...` Firestore build). Gating on the
/// client ID means an unconfigured build shows no button rather than a button
/// that throws — email/password stays the fallback. iOS/others remain off.
bool get googleSignInSupported =>
    kIsWeb ||
    (defaultTargetPlatform == TargetPlatform.android &&
        _googleServerClientId.isNotEmpty);

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
