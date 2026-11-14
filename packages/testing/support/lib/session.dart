/// Test doubles for the user session's lifetime (#694): a `SessionLease` a
/// screen suite ends by hand, in place of the one `UserScopeHost` registers
/// in each user-session scope.
///
/// Needs only `interfaces`, which is pure Dart, so it is separate from
/// `widgets.dart` for the same reason `access.dart` is (#354).
library;

export 'src/session/fake_session_lease.dart';
