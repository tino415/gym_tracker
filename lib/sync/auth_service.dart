import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_backend.dart';
import 'firestore_transport.dart';
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
/// [authStateProvider] and keeps exactly one [FirestoreSyncTransport] bound to
/// the current uid attached to the running [SyncService]: attach on sign-in,
/// detach+dispose on sign-out, and swap old→new on account switch. Signed out,
/// no transport is attached, so the app makes zero Firestore calls.
///
/// The body deliberately depends on nothing that changes (it only reads
/// [syncServiceProvider] and *listens* to [authStateProvider], which itself
/// gates on Firebase init), so it runs exactly once — the attach state below
/// lives in closure locals that must survive for the app's lifetime.
final firestoreSyncBinderProvider = Provider<void>((ref) {
  if (!syncBackendEnabled) return; // backend not compiled in; stay inert

  final svc = ref.read(syncServiceProvider);
  FirestoreSyncTransport? current;
  String? currentUid;
  // Sticky across sign-out (unlike [currentUid]): the last uid we attached a
  // transport for. Lets us detect an account *switch* so we don't auto-push
  // this device's local data — which may include a previous account's routines
  // synced down earlier — up into a different account. First sign-in (null) and
  // re-sign-in to the same account still push, so local-first backup is intact.
  String? lastAttachedUid;

  ref.listen<AsyncValue<User?>>(authStateProvider, (prev, next) {
    final uid = next.valueOrNull?.uid;
    if (uid == currentUid) return; // no change (also ignores token refresh)

    // Detach the old transport (uid changed or signed out). removeTransport
    // mutates SyncService's collections synchronously before its first await,
    // so the remove(old)+add(new) pair below never interleaves.
    final old = current;
    if (old != null) {
      current = null;
      currentUid = null;
      unawaited(svc.removeTransport(old));
    }
    // Attach a fresh transport for the new uid. On first sign-in / same-account
    // re-sign-in, addTransport pushes local data up (backup). On an account
    // switch it attaches receive-only, so account B doesn't silently inherit
    // account A's routines (the user can still push explicitly via Sync now).
    if (uid != null) {
      final switchingAccount =
          lastAttachedUid != null && lastAttachedUid != uid;
      final t = FirestoreSyncTransport(uid: uid);
      current = t;
      currentUid = uid;
      lastAttachedUid = uid;
      svc.addTransport(t, pushOnAttach: !switchingAccount);
    }
  }, fireImmediately: true);

  ref.onDispose(() {
    final old = current;
    if (old != null) unawaited(svc.removeTransport(old));
  });
});
