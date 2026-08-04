import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../sync/health_connect_bridge.dart';

/// SharedPreferences key for the Health Connect opt-in.
const healthConnectPrefsKey = 'health_connect_enabled';

/// Read the persisted opt-in from [prefs]. Used by `main()` to seed
/// [initialHealthConnectEnabledProvider].
bool healthConnectEnabledFromPrefs(SharedPreferences prefs) =>
    prefs.getBool(healthConnectPrefsKey) ?? false;

/// Seed for the controller's initial state, overridden in `main()` from
/// SharedPreferences — the same shape as the theme.
///
/// Seeding rather than loading lazily matters here: the run page reads this
/// when a workout finishes, and a user who never opened the account screen this
/// session would otherwise look opted-out and silently publish nothing.
final initialHealthConnectEnabledProvider = Provider<bool>((_) => false);

/// Whether finished workouts are published to Health Connect.
///
/// Off until the user turns it on: writing a person's training to a
/// system-wide health store is not something to start doing silently. Kept in
/// SharedPreferences rather than the database because it is a property of this
/// install, not of the account — Health Connect exists on one phone, and
/// syncing the flag would switch it on for devices that have no provider.
class HealthConnectController extends Notifier<bool> {
  @override
  bool build() => ref.watch(initialHealthConnectEnabledProvider);

  /// Turn publishing on or off.
  ///
  /// Turning it on asks Health Connect for the write permissions first and
  /// stays off if they are refused — a switch that flips to "on" while nothing
  /// can actually be written would be a lie. Returns the resulting state.
  Future<bool> set(bool enabled) async {
    if (enabled) {
      final granted = await HealthConnectBridge.instance.hasPermissions() ||
          await HealthConnectBridge.instance.requestPermissions();
      if (!granted) {
        state = false;
        return false;
      }
    }
    state = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(healthConnectPrefsKey, enabled);
    } catch (e, st) {
      debugPrint('health connect prefs write failed: $e\n$st');
    }
    return enabled;
  }
}

final healthConnectEnabledProvider =
    NotifierProvider<HealthConnectController, bool>(
  HealthConnectController.new,
);

/// Whether this device has a Health Connect provider at all, for deciding
/// whether to show the toggle. Unavailable on web, Wear and iOS.
final healthConnectStatusProvider = FutureProvider<HealthConnectStatus>(
  (ref) => HealthConnectBridge.instance.status(),
);
