/// Test doubles for what the signed-in user may do on the server (#456):
/// a `CallerAccessRepository` a screen suite sets by hand, in place of the
/// session's reader.
///
/// Needs only `interfaces` and `models`, which are pure Dart, so it is
/// separate from `widgets.dart` for the same reason `network.dart` is
/// (#354).
library;

export 'src/access/fake_caller_access_repository.dart';
