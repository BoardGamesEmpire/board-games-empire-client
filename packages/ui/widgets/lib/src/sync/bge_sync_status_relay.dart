import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ui/src/sync/bge_sync_status_scope.dart';

/// What a [BgeSyncStatusScope] holds, as plain data a listenable can carry
/// past the tree (#960).
///
/// Each field means what the scope's field of the same name does. As there,
/// [stuckRecordIds] is empty while [stuck] is null; the scope built from
/// this asserts it, as a const constructor can't read a set's contents.
@immutable
class BgeSyncStatusData {
  const BgeSyncStatusData({
    this.waiting,
    this.stuck,
    this.stuckRecordIds = const {},
  });

  /// See [BgeSyncStatusScope.waiting].
  final int? waiting;

  /// See [BgeSyncStatusScope.stuck].
  final int? stuck;

  /// See [BgeSyncStatusScope.stuckRecordIds]. A new set comes with each
  /// state, so two are compared by their contents.
  final Set<String> stuckRecordIds;

  @override
  bool operator ==(Object other) =>
      other is BgeSyncStatusData &&
      other.waiting == waiting &&
      other.stuck == stuck &&
      setEquals(other.stuckRecordIds, stuckRecordIds);

  @override
  int get hashCode => Object.hash(
    waiting,
    stuck,
    Object.hashAllUnordered(stuckRecordIds),
  );

  @override
  String toString() =>
      'BgeSyncStatusData(waiting: $waiting, stuck: $stuck, '
      'stuckRecordIds: $stuckRecordIds)';
}

/// Puts the session's sync state back over [child] where the session's
/// [BgeSyncStatusScope] doesn't reach, from the relay that scope carries
/// (#960).
///
/// A pop-up goes on the root navigator (`showBgePopup`), above the shell
/// and the session's scope under it, so a row in it would read no scope:
/// its own flags could say it was waiting, but never that its change was
/// stuck. Its opener reads [BgeSyncStatusScope.relayOf] and the pop-up's
/// content wraps itself in this, which rebuilds the scope as the relay
/// changes. A row's badge then changes while the pop-up is open: a stuck
/// change that clears says so at once, as it does on the page.
///
/// The scope built here carries [relay] on, for a pop-up opened from this
/// one. A null [relay], from an opener with no session scope above it,
/// passes [child] through as it is, so rows read the flags alone, as with
/// no scope.
class BgeSyncStatusRelayScope extends StatelessWidget {
  const BgeSyncStatusRelayScope({
    required this.relay,
    required this.child,
    super.key,
  });

  /// The session's state, as [BgeSyncStatusScope.relayOf] gave it to the
  /// opener; null where there was none.
  final ValueListenable<BgeSyncStatusData>? relay;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final relay = this.relay;
    if (relay == null) return child;
    return ValueListenableBuilder<BgeSyncStatusData>(
      valueListenable: relay,
      builder: (context, data, child) => BgeSyncStatusScope(
        waiting: data.waiting,
        stuck: data.stuck,
        stuckRecordIds: data.stuckRecordIds,
        relay: relay,
        child: child!,
      ),
      child: child,
    );
  }
}
