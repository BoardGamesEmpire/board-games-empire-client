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
  FixedClockService(this.current);

  /// The instant [nowUtc] returns. Mutate to advance (or rewind) time.
  DateTime current;

  @override
  DateTime nowUtc() => current;

  @override
  Duration? get skewEstimate => null;

  @override
  Stream<Duration?> watchSkew() => Stream<Duration?>.value(null);
}
