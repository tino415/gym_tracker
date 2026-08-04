import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether Health Connect can be used at all on this device.
enum HealthConnectStatus {
  /// Ready to write.
  available,

  /// The provider is installed but too old — Health Connect asks the user to
  /// update it before an app can write.
  updateRequired,

  /// No provider: web, Wear, iOS, or an Android phone where Health Connect
  /// (a separate app below Android 14) was never installed.
  unavailable,
}

/// Dart side of [HealthConnectBridge], for publishing finished workouts to the
/// phone's health store.
///
/// Write-only: the app never reads anything back, which keeps the Play health
/// declaration narrow. Every call no-ops off Android — including on Wear, which
/// has no Health Connect provider — so callers don't need to guard.
class HealthConnectBridge {
  HealthConnectBridge._();

  static final HealthConnectBridge instance = HealthConnectBridge._();

  static const _method = MethodChannel('gym_tracker/health_connect/method');

  Future<HealthConnectStatus> status() async {
    if (_skip) return HealthConnectStatus.unavailable;
    try {
      final raw = await _method.invokeMethod<String>('status');
      return switch (raw) {
        'available' => HealthConnectStatus.available,
        'updateRequired' => HealthConnectStatus.updateRequired,
        _ => HealthConnectStatus.unavailable,
      };
    } catch (_) {
      return HealthConnectStatus.unavailable;
    }
  }

  Future<bool> hasPermissions() => _invokeBool('hasPermissions');

  /// Opens Health Connect's own permission screen. Not a runtime permission
  /// dialog — the result comes back through the activity result, which is why
  /// MainActivity forwards it.
  Future<bool> requestPermissions() => _invokeBool('requestPermissions');

  /// Publish one finished workout.
  ///
  /// [clientRecordId] makes this idempotent: Health Connect replaces a record
  /// carrying the same id rather than adding another, so republishing an edited
  /// or re-synced workout updates in place. Pass the workout's sync id, and its
  /// LWW version as [clientRecordVersion].
  ///
  /// [samples] is `{t: epochMillis, bpm: int}`, oldest first; readings outside
  /// the session window are dropped natively, since Health Connect rejects a
  /// record whose samples fall outside its own bounds.
  ///
  /// Returns false rather than throwing when Health Connect is missing, the
  /// permission was refused, or the times don't form a real interval — the
  /// workout is already saved locally, so publishing is best-effort.
  Future<bool> writeWorkout({
    required int startMs,
    required int endMs,
    String? title,
    String? clientRecordId,
    int clientRecordVersion = 0,
    List<({int tMs, int bpm})> samples = const [],
  }) async {
    if (_skip) return false;
    try {
      final ok = await _method.invokeMethod<bool>('writeWorkout', {
        'startMs': startMs,
        'endMs': endMs,
        'title': title,
        'clientRecordId': clientRecordId,
        'clientRecordVersion': clientRecordVersion,
        'samples': [
          for (final s in samples) {'t': s.tMs, 'bpm': s.bpm},
        ],
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _invokeBool(String method) async {
    if (_skip) return false;
    try {
      return await _method.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True where there is no Health Connect to talk to, or under test.
  static bool get _skip =>
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      debugSkipPlatformCalls ||
      _flutterTestEnv;

  /// Mirrors [WorkoutBridge.debugSkipPlatformCalls]: on-device integration
  /// tests don't set FLUTTER_TEST, so without this they would hit the real
  /// Health Connect permission screen and block.
  static bool debugSkipPlatformCalls = false;

  static final bool _flutterTestEnv = () {
    if (kIsWeb) return false;
    try {
      return Platform.environment['FLUTTER_TEST'] == 'true';
    } catch (_) {
      return false;
    }
  }();
}
