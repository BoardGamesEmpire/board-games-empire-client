import 'package:interfaces/sync.dart';

/// What became of a change's immediate send (#45, #46).
enum CollectionSync {
  /// The server has it.
  synced,

  /// It stays queued: the send didn't reach the server, or an earlier
  /// change to the entry is still waiting. The drain sends it later, on
  /// both platforms.
  queued,

  /// The server refused it. It is kept on this device and won't be sent
  /// again on its own: the user retries or discards it where changes that
  /// couldn't sync are listed (#190).
  refused;

  /// What became of a change whose send ended in [delivery].
  static CollectionSync of(SyncDelivery delivery) => switch (delivery) {
    SyncDelivered() => synced,
    SyncParked() => refused,
    SyncNotClaimed() || SyncFailed() => queued,
  };
}
