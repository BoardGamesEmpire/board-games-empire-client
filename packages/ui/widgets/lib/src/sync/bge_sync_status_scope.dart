import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/widgets.dart';
import 'package:ui/src/sync/bge_sync_badge.dart';

/// What the session's sync queue holds, for the rows and lines below it
/// (#47).
///
/// Presentation-only: the host reads the queue and passes plain data in, so
/// this package keeps no sync dependency, and no feature bloc has to carry a
/// row's sync state.
///
/// Every lookup falls back to knowing nothing, so a widget pumped without a
/// scope behaves as it did before the scope existed: no counts, nothing
/// stuck, and a row still says it is waiting from its own flags.
///
/// The two counts are known or not on their own, as the queue reads them
/// from two streams: a null count is one not read, before its first read
/// or while its last one failed. The stuck records stand with [stuck], not
/// with [waiting], so a row whose change is stuck says so whatever the
/// pending count is doing.
///
/// Each lookup depends on its own part of the state. A row depends on its
/// own record's id alone, so a count changing rebuilds no row, and a record
/// getting stuck or unstuck rebuilds only that record's rows.
class BgeSyncStatusScope extends InheritedModel<Object> {
  // Not const: a const constructor's assert can't read a set's contents.
  BgeSyncStatusScope({
    required super.child,
    this.waiting,
    this.stuck,
    this.stuckRecordIds = const {},
    super.key,
  }) : assert(
         stuck != null || stuckRecordIds.isEmpty,
         'records are named only from a read of the stuck changes',
       );

  /// How many changes are queued and not yet sent; null where the queue's
  /// pending count hasn't been read, or its last read failed, and with no
  /// queue at all, where a zero would claim everything had gone.
  final int? waiting;

  /// How many changes will not send on their own; null where the queue's
  /// stuck changes haven't been read, or their last read failed, and with
  /// no queue at all, where a zero would claim nothing was stuck.
  final int? stuck;

  /// The records the [stuck] changes name; empty while [stuck] is null. A
  /// stuck change whose record can't be read counts in [stuck] and names
  /// nothing here.
  ///
  /// The host makes a new set for each state, so changes compare it by its
  /// contents.
  final Set<String> stuckRecordIds;

  static BgeSyncStatusScope? _of(BuildContext context, Object aspect) =>
      InheritedModel.inheritFrom<BgeSyncStatusScope>(context, aspect: aspect);

  /// The waiting and stuck counts, each null where it hasn't been read, and
  /// both null with no scope.
  static ({int? waiting, int? stuck}) countsOf(BuildContext context) {
    final scope = _of(context, _Aspect.counts);
    return (waiting: scope?.waiting, stuck: scope?.stuck);
  }

  /// Whether a change to [recordId] is stuck; false with no scope, or where
  /// the stuck changes haven't been read, which names no records.
  static bool isStuckOf(BuildContext context, String recordId) =>
      _of(context, recordId)?.stuckRecordIds.contains(recordId) ?? false;

  /// The state a row for [recordId] shows, given whether the record's own
  /// flags say the server hasn't had it ([unsynced]).
  ///
  /// Stuck wins, as only the queue knows a change will not send on its own;
  /// then waiting; and null for a record the server has.
  static BgeSyncState? stateOf(
    BuildContext context, {
    required String recordId,
    required bool unsynced,
  }) {
    if (isStuckOf(context, recordId)) return BgeSyncState.stuck;
    return unsynced ? BgeSyncState.waiting : null;
  }

  @override
  bool updateShouldNotify(BgeSyncStatusScope oldWidget) =>
      _countsChanged(oldWidget) ||
      !setEquals(stuckRecordIds, oldWidget.stuckRecordIds);

  @override
  bool updateShouldNotifyDependent(
    BgeSyncStatusScope oldWidget,
    Set<Object> dependencies,
  ) => dependencies.any(
    (aspect) => switch (aspect) {
      _Aspect.counts => _countsChanged(oldWidget),
      final String recordId =>
        stuckRecordIds.contains(recordId) !=
            oldWidget.stuckRecordIds.contains(recordId),
      _ => false,
    },
  );

  bool _countsChanged(BgeSyncStatusScope oldWidget) =>
      waiting != oldWidget.waiting || stuck != oldWidget.stuck;
}

/// The parts of [BgeSyncStatusScope] a widget can depend on, besides a
/// record's id, which is its own aspect.
enum _Aspect {
  /// [BgeSyncStatusScope.waiting] and [BgeSyncStatusScope.stuck], read or
  /// not.
  counts,
}
