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

/// Dart side of the Wear OS foreground workout service. Mirrors the
/// `WearBridge` pattern: a singleton with lazy channel binding.
class WorkoutBridge {
  WorkoutBridge._();

  static final WorkoutBridge instance = WorkoutBridge._();

  static const _method = MethodChannel('gym_tracker/workout/method');
  static const _events = EventChannel('gym_tracker/workout/events');

  final StreamController<HeartRateSample> _heartRate =
      StreamController<HeartRateSample>.broadcast();
  HeartRateSample? _lastSample;
  // ignore: unused_field
  StreamSubscription<Object?>? _eventsSub;
  bool _bound = false;

  Stream<HeartRateSample> get heartRateStream => _heartRate.stream;
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
    if (type != 'heartRate' || payload is! Map) return;
    final bpm = payload['bpm'];
    final ts = payload['timestampMs'];
    if (bpm is! int || ts is! int) return;
    final sample = HeartRateSample(bpm: bpm, timestampMs: ts);
    _lastSample = sample;
    _heartRate.add(sample);
  }

  /// Spin up the foreground service + Health Services subscription. Safe to
  /// call multiple times — the service deduplicates.
  Future<void> start({required String routineName}) async {
    _ensureBound();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_skipPlatformCalls) return;
    try {
      await _method.invokeMethod<void>('start', <String, Object?>{
        'routineName': routineName,
      });
    } on MissingPluginException {
      // No native handler. Silently no-op.
    }
  }

  Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_skipPlatformCalls) return;
    try {
      await _method.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No-op.
    }
    _lastSample = null;
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

  /// `flutter test` sets the `FLUTTER_TEST` env var. Skipping platform calls
  /// here means the run-page widget tests don't need to mock the channel.
  static final bool _skipPlatformCalls = () {
    if (kIsWeb) return false;
    try {
      return Platform.environment['FLUTTER_TEST'] == 'true';
    } catch (_) {
      return false;
    }
  }();
}
