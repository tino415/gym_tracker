import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class HeartRateSample {
  HeartRateSample({required this.bpm, required this.timestampMs});

  final int bpm;
  final int timestampMs;

  DateTime get timestamp =>
      DateTime.fromMillisecondsSinceEpoch(timestampMs);

  /// True if this sample is more recent than [maxAge] (default 10 s). Used to
  /// hide the HR badge when sensor reads have dropped out.
  bool isFresh({Duration maxAge = const Duration(seconds: 10)}) {
    final age = DateTime.now().millisecondsSinceEpoch - timestampMs;
    return age >= 0 && age <= maxAge.inMilliseconds;
  }
}

/// Countdown kinds exchanged with the native workout service over [setTimer]
/// and the `timerDone` event. Mirror `WorkoutService.KIND_REST` / `KIND_TIME`
/// on the Kotlin side — keep the three in sync.
const String kTimerKindRest = 'rest';
const String kTimerKindTime = 'time';

/// Dart side of the Wear OS foreground workout service. Mirrors the
/// `WearBridge` pattern: a singleton with lazy channel binding.
class WorkoutBridge {
  WorkoutBridge._();

  static final WorkoutBridge instance = WorkoutBridge._();

  static const _method = MethodChannel('gym_tracker/workout/method');
  static const _events = EventChannel('gym_tracker/workout/events');

  final StreamController<HeartRateSample> _heartRate =
      StreamController<HeartRateSample>.broadcast();
  // Emits the kind ('rest' | 'time') of a countdown that the native service
  // fired (and vibrated for), so the watch run page advances even if its own
  // periodic ticker was frozen by the screen sleeping.
  final StreamController<String> _timerDone =
      StreamController<String>.broadcast();
  HeartRateSample? _lastSample;
  // ignore: unused_field
  StreamSubscription<Object?>? _eventsSub;
  bool _bound = false;

  Stream<HeartRateSample> get heartRateStream => _heartRate.stream;
  Stream<String> get timerDoneStream => _timerDone.stream;
  HeartRateSample? get lastSample => _lastSample;

  void _ensureBound() {
    if (_bound) return;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        _skipPlatformCalls) {
      _bound = true;
      return;
    }
    _bound = true;
    _eventsSub = _events.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(Object? raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    final payload = raw['payload'];
    if (payload is! Map) return;
    if (type == 'heartRate') {
      final bpm = payload['bpm'];
      final ts = payload['timestampMs'];
      if (bpm is! int || ts is! int) return;
      final sample = HeartRateSample(bpm: bpm, timestampMs: ts);
      _lastSample = sample;
      _heartRate.add(sample);
    } else if (type == 'timerDone') {
      final kind = payload['kind'];
      if (kind is String) _timerDone.add(kind);
    }
  }

  /// Fire-and-forget method call shared by the void-returning commands. Skips
  /// the platform under web / non-Android / `flutter test`, and swallows the
  /// no-native-handler case.
  Future<void> _invokeVoid(String method, [Map<String, Object?>? args]) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        _skipPlatformCalls) {
      return;
    }
    try {
      await _method.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No native handler. Silently no-op.
    }
  }

  /// Spin up the foreground service + Health Services subscription. Safe to
  /// call multiple times — the service deduplicates.
  Future<void> start({required String routineName}) async {
    _ensureBound();
    await _invokeVoid('start', <String, Object?>{'routineName': routineName});
  }

  Future<void> stop() async {
    await _invokeVoid('stop');
    _lastSample = null;
  }

  /// Schedule a native vibration at [endTimeMs] (epoch millis) for a countdown
  /// of [kind] ([kTimerKindRest] | [kTimerKindTime]). The native service holds
  /// a wake lock so this fires even with the screen off; it then emits a
  /// `timerDone` event. Returns true iff the native call was dispatched — the
  /// caller falls back to a Dart haptic when it returns false (no bridge,
  /// platform error, or test/web) so a completion buzz is never lost.
  Future<bool> setTimer({
    required String kind,
    required int endTimeMs,
  }) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        _skipPlatformCalls) {
      return false;
    }
    try {
      await _method.invokeMethod<void>('setTimer', <String, Object?>{
        'kind': kind,
        'endTimeMs': endTimeMs,
      });
      return true;
    } catch (_) {
      // MissingPluginException (no handler) or any PlatformException (bridge /
      // service error). Report failure so the caller buzzes in Dart instead.
      return false;
    }
  }

  /// Cancel a pending native countdown vibration (skip / bump-reschedule /
  /// teardown).
  Future<void> clearTimer() async {
    await _invokeVoid('clearTimer');
  }

  Future<bool> hasBodySensorsPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    if (_skipPlatformCalls) return false;
    try {
      final r = await _method.invokeMethod<bool>('hasBodySensorsPermission');
      return r ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Prompts for BODY_SENSORS (+ POST_NOTIFICATIONS on API 33+). Returns true
  /// if every requested permission was granted.
  Future<bool> requestPermissions() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    if (_skipPlatformCalls) return false;
    try {
      final r = await _method.invokeMethod<bool>('requestPermissions');
      return r ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// When true, every platform call is skipped even outside a host `flutter
  /// test` run. On-device integration tests (`flutter test … -d DEVICE`) do
  /// *not* set `FLUTTER_TEST` in the app process, so without this the run page
  /// would fire a real BODY_SENSORS/notifications permission dialog that blocks
  /// the test. Integration tests set this true before pumping the widget tree.
  static bool debugSkipPlatformCalls = false;

  /// Whether to no-op platform calls: host `flutter test` (via `FLUTTER_TEST`)
  /// or an integration test that opted in via [debugSkipPlatformCalls].
  static bool get _skipPlatformCalls =>
      _flutterTestEnv || debugSkipPlatformCalls;

  /// `flutter test` sets the `FLUTTER_TEST` env var. Skipping platform calls
  /// here means the run-page widget tests don't need to mock the channel.
  static final bool _flutterTestEnv = () {
    if (kIsWeb) return false;
    try {
      return Platform.environment['FLUTTER_TEST'] == 'true';
    } catch (_) {
      return false;
    }
  }();
}
