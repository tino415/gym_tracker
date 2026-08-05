import 'dart:async';

import 'wear_bridge.dart';

/// One sync message: a type tag (see sync_codec.dart constants) plus a
/// JSON-shaped payload.
class SyncMessage {
  SyncMessage({required this.type, required this.payload});
  final String type;
  final Map<String, Object?> payload;
}

/// A channel that carries sync messages between this device and a peer —
/// the paired phone/watch over the Wear Data Layer, or a server. SyncService
/// fans sends out to every registered transport and merges their inbound
/// streams; transports never interpret message contents.
abstract interface class SyncTransport {
  /// Inbound messages from the peer. Listened to exactly once by SyncService.
  Stream<SyncMessage> get messages;

  Future<void> send({
    required String type,
    required Map<String, Object?> payload,
  });

  /// Activate the underlying channel (idempotent).
  void start();

  /// Deliver messages that arrived while this device's app was not running.
  ///
  /// Called once by [SyncService.start] *after* it has subscribed to
  /// [messages], and must push onto [messages] rather than applying anything
  /// itself. Transports with no offline queue return immediately.
  Future<void> drainPending();

  Future<void> dispose();
}

/// Phone ↔ watch transport over the hand-rolled Wear Data Layer bridge.
class WearSyncTransport implements SyncTransport {
  WearSyncTransport({WearBridge? bridge})
    : _bridge = bridge ?? WearBridge.instance;

  final WearBridge _bridge;

  @override
  Stream<SyncMessage> get messages => _bridge.messages.map(
    (m) => SyncMessage(type: m.type, payload: m.payload),
  );

  @override
  Future<void> send({
    required String type,
    required Map<String, Object?> payload,
  }) {
    return _bridge.send(type: type, payload: payload);
  }

  @override
  void start() => _bridge.start();

  @override
  Future<void> drainPending() => _bridge.drainPending();

  @override
  Future<void> dispose() async {
    // The bridge is a process-wide singleton shared with reachability UI;
    // nothing to tear down per-transport.
  }
}
