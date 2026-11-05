/// Transport-level test helpers: real `Dio` instances whose adapter is
/// swapped for a canned one (or for a scripted, recording `ScriptedServer`
/// that root-level tests can route, hold and drop answers on), so a suite
/// exercises Dio's own body pipeline (transformer, cast, `assureDioException`)
/// rather than a `MockDio` that stubs it away.
///
/// Needs only `dio`. Kept separate from `widgets.dart` so a consumer that wants
/// the transport helpers does not pull the `flutter_test` surface into scope —
/// and so this library could be split into its own package unchanged if a
/// pure-Dart consumer ever appears (#354 D1).
library;

export 'src/network/canned_adapter.dart';
export 'src/network/routing_adapter.dart';
export 'src/network/scripted_server.dart';
