import 'dart:async';

import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

/// A [CallerAccessRepository] whose answer a test sets by hand (#456).
///
/// Setting [current] emits on [changes] only when the answer differs from the
/// last, as the contract says. The stream is broadcast and delivers a
/// microtask later, as the session's real reader does, so a screen suite
/// meets the timing the app will.
///
/// [refresh] asks nothing: it counts the call in [refreshCount] and leaves
/// [current] alone, so a test can set the answer a refresh would have found.
///
/// [dispose] closes [changes], as the reader's does when the user scope pops,
/// so a suite can end a session the way the app does.
class FakeCallerAccessRepository implements CallerAccessRepository {
  /// Starts at [initial], unknown by default.
  FakeCallerAccessRepository([
    CallerAccess initial = const CallerAccess.unknown(),
  ]) : _current = initial;

  /// A known answer for DataGateways alone, with `manage` none, which no
  /// DataGateway screen reads.
  static CallerAccess dataGateway({
    AccessExtent create = AccessExtent.none,
    AccessExtent read = AccessExtent.none,
    AccessExtent update = AccessExtent.none,
    AccessExtent delete = AccessExtent.none,
  }) => CallerAccess.known({
    ResourceType.dataGateway: ResourceAccess(
      create: create,
      read: read,
      update: update,
      delete: delete,
      manage: AccessExtent.none,
    ),
  });

  /// A known answer with each type's `read` as given and every other action
  /// none.
  static CallerAccess of(Map<ResourceType, AccessExtent> reads) =>
      CallerAccess.known({
        for (final entry in reads.entries)
          entry.key: ResourceAccess(
            create: AccessExtent.none,
            read: entry.value,
            update: AccessExtent.none,
            delete: AccessExtent.none,
            manage: AccessExtent.none,
          ),
      });

  final StreamController<CallerAccess> _changes =
      StreamController<CallerAccess>.broadcast();

  CallerAccess _current;
  bool _disposed = false;

  /// How many times [refresh] was called.
  int refreshCount = 0;

  @override
  CallerAccess get current => _current;

  /// Replaces the answer, emitting it if it differs from the last. Dropped
  /// after [dispose], as the reader drops an answer that lands after its
  /// session ended.
  set current(CallerAccess next) {
    if (_disposed || next == _current) return;
    _current = next;
    _changes.add(next);
  }

  @override
  late final Stream<CallerAccess> changes = _changes.stream;

  @override
  Future<void> refresh() async {
    refreshCount++;
  }

  /// Closes [changes] and keeps [current] as it was.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.close());
  }
}
