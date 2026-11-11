import 'package:models/dto.dart';

/// A granted session for user `u1`, expiring far in the future.
///
/// Shared (#409): suites used to hand-roll their own copies, which drifted;
/// they now share this one and vary it with `copyWith`, and the user with the
/// nested form: `testAuthResponse().copyWith.user(id: 'u2')`.
AuthResponse testAuthResponse() => AuthResponse(
  token: 'tok-abc',
  user: AuthUser(
    id: 'u1',
    username: 'testuser',
    email: 'u1@example.com',
    emailVerified: true,
    createdAt: DateTime(2099),
    updatedAt: DateTime(2099),
  ),
  expiresAt: DateTime(2099).toUtc(),
);
