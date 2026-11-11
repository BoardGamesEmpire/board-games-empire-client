/// Shared builders for the domain models nearly every suite needs (#409): a
/// `ServerIdentity` and the `AuthResponse` a granted sign-in returns.
///
/// Needs only `models`, which is pure Dart, so it is separate from
/// `widgets.dart` for the same reason `network.dart` is (#354).
library;

export 'src/domain/auth_response_fixtures.dart';
export 'src/domain/server_identity_fixtures.dart';
