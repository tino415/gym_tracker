import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/sync/wear_bridge.dart';

/// Covers the drain hand-off: the native side parks inbound messages on disk
/// while no engine is running and returns them from `drainPending`, and they
/// must surface on [WearBridge.messages] exactly as a live event would — that
/// sameness is what lets SyncService apply them with no second code path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('gym_tracker/wear/method');

  late List<MethodCall> calls;
  Object? drainReply;

  setUp(() {
    calls = [];
    drainReply = <Object?>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return switch (call.method) {
        'drainPending' => drainReply,
        _ => null,
      };
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null);
  });

  Map<Object?, Object?> event(String type, Map<Object?, Object?> payload) =>
      <Object?, Object?>{'type': type, 'payload': payload};

  test('queued messages surface on messages, in order', () async {
    drainReply = <Object?>[
      event('routine_bundle', {'routines': <Object?>[]}),
      event('workout_completed', {'syncId': 'w1', 'version': 3}),
    ];
    final bridge = WearBridge.forTesting();
    final seen = <WearMessage>[];
    bridge.messages.listen(seen.add);

    await bridge.drainPending();
    await Future<void>.delayed(Duration.zero);

    expect(seen.map((m) => m.type),
        ['routine_bundle', 'workout_completed']);
    expect(seen[1].payload, {'syncId': 'w1', 'version': 3});
    expect(calls.map((c) => c.method), contains('drainPending'));
  });

  test('an empty queue emits nothing', () async {
    final bridge = WearBridge.forTesting();
    final seen = <WearMessage>[];
    bridge.messages.listen(seen.add);

    await bridge.drainPending();
    await Future<void>.delayed(Duration.zero);

    expect(seen, isEmpty);
  });

  test('a reachability entry is routed to reachability, not messages',
      () async {
    // The native side reserves this type for its own control events; a queued
    // one must not be mistaken for a sync message.
    drainReply = <Object?>[
      event('_reachability', {'state': 'reachable'}),
      event('routine_bundle', {'routines': <Object?>[]}),
    ];
    final bridge = WearBridge.forTesting();
    final seen = <WearMessage>[];
    final reach = <WearReachability>[];
    bridge.messages.listen(seen.add);
    bridge.reachability.listen(reach.add);

    await bridge.drainPending();
    await Future<void>.delayed(Duration.zero);

    expect(seen.map((m) => m.type), ['routine_bundle']);
    expect(reach, [WearReachability.reachable]);
  });

  test('a malformed entry is skipped rather than throwing', () async {
    drainReply = <Object?>[
      'not a map',
      <Object?, Object?>{'type': 42, 'payload': <Object?, Object?>{}},
      event('routine_bundle', {'routines': <Object?>[]}),
    ];
    final bridge = WearBridge.forTesting();
    final seen = <WearMessage>[];
    bridge.messages.listen(seen.add);

    await bridge.drainPending();
    await Future<void>.delayed(Duration.zero);

    expect(seen.map((m) => m.type), ['routine_bundle']);
  });

  test('a platform failure is swallowed so startup continues', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      if (call.method == 'drainPending') {
        throw PlatformException(code: 'drain_failed');
      }
      return null;
    });
    final bridge = WearBridge.forTesting();

    await expectLater(bridge.drainPending(), completes);
    expect(calls.map((c) => c.method), contains('drainPending'));
  });

  test('does nothing off Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final bridge = WearBridge.forTesting();

    await bridge.drainPending();

    expect(calls.where((c) => c.method == 'drainPending'), isEmpty);
  });
}
