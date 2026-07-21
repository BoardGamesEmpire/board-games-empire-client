import 'package:interfaces/services.dart';

/// Pass-through [ClockService] test double returning the real wall
/// clock.
///
/// For pre-existing tests that exercise repository semantics — not
/// timestamp origin — and rely on real time advancing between
/// operations (e.g. `updatedAt`-ordering assertions). Lives in test
/// support, alongside [FixedClockService], so the storage test suite
/// depends only on the `interfaces` package like the production code
/// it tests — not on the `di` composition package.
class SystemClockService implements ClockService {
  /// Creates the double.
  const SystemClockService();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();

  @override
  Duration? get skewEstimate => null;

  @override
  Stream<Duration?> watchSkew() => Stream<Duration?>.value(null);
}
