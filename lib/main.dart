import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wear_plus/wear_plus.dart';

import 'phone/phone_app.dart';
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
    // Eagerly create the sync service so it subscribes to local DB updates
    // and inbound messages even before any UI route reads it.
    ref.watch(syncServiceProvider);
    if (isWatch) return const _WearShell();
    return const PhoneApp();
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
