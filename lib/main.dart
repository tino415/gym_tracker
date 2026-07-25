import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wear_plus/wear_plus.dart';

import 'data/providers.dart';
import 'phone/phone_app.dart';
import 'phone/sign_in_screen.dart';
import 'sync/auth_service.dart';
import 'sync/firestore_backend.dart';
import 'sync/sync_service.dart';
import 'watch/watch_app.dart';
import 'watch/widgets/round_safe_area.dart';

const _platformChannel = MethodChannel('gym_tracker/platform');

Future<bool> _detectIsWatch() async {
  if (kIsWeb) return false;
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await _platformChannel.invokeMethod<bool>('isWatch') ?? false;
  } catch (_) {
    return false;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final isWatch = await _detectIsWatch();
  runApp(
    ProviderScope(
      overrides: [isWatchProvider.overrideWithValue(isWatch)],
      child: GymTrackerRoot(isWatch: isWatch),
    ),
  );
}

/// Whether this build is running on a Wear OS device. Overridden in main.dart
/// after platform detection; default is false so unit tests pick the phone
/// branch.
final isWatchProvider = Provider<bool>((ref) => false);

class GymTrackerRoot extends ConsumerWidget {
  const GymTrackerRoot({super.key, required this.isWatch});

  final bool isWatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The server-backed web build reads/writes Firestore directly: no local
    // Drift DB, no SyncService/transports (the repositories are the data
    // layer), and it is auth-gated — signed-in by construction.
    if (ref.watch(firestoreDirectProvider)) {
      return const _FirestoreDirectApp();
    }
    // Phone/watch: local Drift + sync. Eagerly create the sync service so it
    // subscribes to local DB updates and inbound messages before any route
    // reads it.
    ref.watch(syncServiceProvider);
    // Kick off optional server-backed sync (no-op unless built with
    // --dart-define=SYNC_BACKEND=firestore). The binder attaches a Firestore
    // transport reactively when the user signs in, and detaches on sign-out.
    // Never on the watch, which reaches the server through the phone.
    if (!isWatch) ref.watch(firestoreSyncBinderProvider);
    if (isWatch) return const _WearShell();
    return const PhoneApp();
  }
}

/// App root for the Firestore-direct web build: waits for Firebase to
/// initialize, then gates on auth — sign-in screen when signed out, the app
/// once signed in (the repositories resolve to their Firestore implementations
/// keyed by the signed-in uid).
class _FirestoreDirectApp extends ConsumerWidget {
  const _FirestoreDirectApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(firebaseReadyProvider);
    return ready.when(
      loading: () => const _BootScreen(),
      error: (e, _) => _BootScreen(message: 'Cloud backend error: $e'),
      data: (ok) {
        if (!ok) {
          return const _BootScreen(message: 'Cloud backend unavailable.');
        }
        final user = ref.watch(authStateProvider).valueOrNull;
        if (user == null) {
          return const MaterialApp(
            title: 'Gym Tracker',
            home: SignInScreen(),
          );
        }
        return const PhoneApp();
      },
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen({this.message});
  final String? message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gym Tracker',
      home: Scaffold(
        body: Center(
          child: message == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(message!, textAlign: TextAlign.center),
                ),
        ),
      ),
    );
  }
}

class _WearShell extends StatelessWidget {
  const _WearShell();

  @override
  Widget build(BuildContext context) {
    return WatchShape(
      builder: (context, shape, child) {
        return WatchShapeScope(
          isRound: shape == WearShape.round,
          child: AmbientMode(
            builder: (context, mode, child) =>
                WatchApp(ambient: mode == WearMode.ambient),
          ),
        );
      },
    );
  }
}
