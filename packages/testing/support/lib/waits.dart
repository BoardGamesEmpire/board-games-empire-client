/// Waits for root-level suites: the session work a composition root starts
/// after the call that started it returns, which a test waits on before it
/// reads the cache or counts requests (#369).
///
/// Shared by the native and web root suites, which each copied them before,
/// so that a fix to one cannot miss the other. Needs only `hydration`, which
/// is pure Dart.
library;

export 'src/waits/await_refreshed.dart';
export 'src/waits/poll_until.dart';
