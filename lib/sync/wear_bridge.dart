import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum WearReachability { notPaired, pairedButNotReachable, reachable }

class WearMessage {
  WearMessage({required this.type, required this.payload});
  final String type;
  final Map<String, Object?> payload;
}

class WearBridge {
  WearBridge._();

  /// A fresh, unbound instance. The singleton latches [_bound] on first use and
  /// keeps a process-wide subscription, so a test needs its own.
  @visibleForTesting
  factory WearBridge.forTesting() = WearBridge._;

  static final WearBridge instance = WearBridge._();

  static const _method = MethodChannel('gym_tracker/wear/method');
  static const _events = EventChannel('gym_tracker/wear/events');

  final StreamController<WearMessage> _messages =
      StreamController<WearMessage>.broadcast();
  final StreamController<WearReachability> _reachability =
      StreamController<WearReachability>.broadcast();
  WearReachability _lastReachability = WearReachability.notPaired;
  // ignore: unused_field
  StreamSubscription<Object?>? _eventsSub;
  bool _bound = false;

  Stream<WearMessage> get messages => _messages.stream;
  Stream<WearReachability> get reachability => _reachability.stream;
  WearReachability get currentReachability => _lastReachability;

  void _ensureBound() {
    if (_bound) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      _bound = true;
      return;
    }
    _bound = true;
    _eventsSub = _events.receiveBroadcastStream().listen(_onEvent);
    unawaited(_method.invokeMethod<void>('refreshReachability'));
  }

  void _onEvent(Object? raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    final payload = raw['payload'];
    if (type is! String || payload is! Map) return;
    final body = payload.map((k, v) => MapEntry(k.toString(), v));
    if (type == '_reachability') {
      final state = body['state'];
      if (state is String) {
        final r = switch (state) {
          'notPaired' => WearReachability.notPaired,
          'pairedButNotReachable' => WearReachability.pairedButNotReachable,
          'reachable' => WearReachability.reachable,
          _ => WearReachability.notPaired,
        };
        _lastReachability = r;
        _reachability.add(r);
      }
      return;
    }
    _messages.add(WearMessage(type: type, payload: body));
  }

  Future<void> send({
    required String type,
    required Map<String, Object?> payload,
  }) async {
    _ensureBound();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _method.invokeMethod<void>('send', <String, Object?>{
      'type': type,
      'payload': payload,
    });
  }

  /// Replay inbound messages that arrived while no Flutter engine was running.
  ///
  /// The native listener service parks them on disk (see `SyncQueue.kt`) and
  /// hands them back in the same shape as a live event, so they go out on
  /// [messages] and are applied by the ordinary inbound path — there is no
  /// second decode and no second apply. Best-effort: a failure here must not
  /// stop the rest of startup.
  Future<void> drainPending() async {
    _ensureBound();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final queued = await _method.invokeListMethod<Object?>('drainPending');
      for (final entry in queued ?? const <Object?>[]) {
        _onEvent(entry);
      }
    } catch (_) {
      // best-effort
    }
  }

  /// Subscribe to inbound events. Calling this for the first time activates
  /// the underlying EventChannel.
  void start() => _ensureBound();
}
