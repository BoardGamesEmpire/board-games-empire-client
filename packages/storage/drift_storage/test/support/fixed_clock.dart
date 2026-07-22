import 'package:interfaces/services.dart';

/// Deterministic [ClockService] test double.
///
/// Returns [current] from [nowUtc] until the test mutates it —
/// letting tests pin repository-produced timestamps (tombstone
/// `deletedAt`, resurrection `updatedAt`, queue `createdAt` /
/// `lastAttemptAt`) to exact instants and advance time explicitly
/// between operations.
class FixedClockService implements ClockService {
  /// Creates the double, initially frozen at [current].
  ///
  /// Asserts UTC: [ClockService.nowUtc] is contractually UTC, and a
  /// local-time instant slipping in would produce subtle store-side
  /// comparisons against UTC columns. Fail fast in tests instead.
  FixedClockService(DateTime current)
    : assert(current.isUtc, 'FixedClockService requires UTC instants'),
      _current = current;

  DateTime _current;

  /// The instant [nowUtc] returns. Mutate to advance (or rewind) time;
  /// asserts UTC like the constructor.
  DateTime get current => _current;

  set current(DateTime value) {
    assert(value.isUtc, 'FixedClockService requires UTC instants');
    _current = value;
  }

  @override
  DateTime nowUtc() => _current;

  @override
  Duration? get skewEstimate => null;

  @override
  Stream<Duration?> watchSkew() => Stream<Duration?>.multi((controller) {
    controller
      ..add(null)
      ..close();
  });
}
