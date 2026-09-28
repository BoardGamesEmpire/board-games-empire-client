import 'package:bloc_test/bloc_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';

/// Shared fixtures for the auth feature's suites (#102): the bloc double the
/// widget suites drive, the repository double the bloc suites drive, and the
/// server identity and session they build.

class MockAuthBloc extends MockBloc<AuthEvent, AuthBlocState>
    implements AuthBloc {}

class MockAuthRepository extends Mock implements AuthRepository {}

const _kAuthBase = '/api/auth';

/// A server identity advertising the strategies a suite asks for: email and
/// password by default, open for sign-up unless [signUpDisabled].
ServerIdentity testServerIdentity({
  bool hasEmailPassword = true,
  bool signUpDisabled = false,
  bool hasOidc = false,
}) => ServerIdentity(
  serverId: 'server-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [
    if (hasEmailPassword)
      EmailAndPasswordStrategy(
        signUpDisabled: signUpDisabled,
        signInEndpoint: '$_kAuthBase/sign-in/email',
        signUpEndpoint: signUpDisabled ? null : '$_kAuthBase/sign-up/email',
      ),
    if (hasOidc)
      const OidcStrategy(
        providerId: 'acme-sso',
        discoveryUrl: 'https://auth.acme.com/.well-known/openid-configuration',
        authorizationEndpoint: '$_kAuthBase/sign-in/oauth2',
      ),
  ],
);

/// A granted session for user `u1`, expiring far in the future.
AuthResponse testSession({String token = 'tok-abc'}) => AuthResponse(
  token: token,
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
