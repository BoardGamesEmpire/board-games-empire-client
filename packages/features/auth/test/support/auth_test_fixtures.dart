import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

/// Shared fixtures for the auth feature's suites (#102): the bloc double the
/// widget suites drive and the repository double the bloc suites drive. The
/// server identity and session they build come from `bge_test_support`'s
/// `domain.dart` (#409).

class MockAuthBloc extends MockBloc<AuthEvent, AuthBlocState>
    implements AuthBloc {}

class MockAuthRepository extends Mock implements AuthRepository {}

/// Stubs what [bloc] says about provider sign-in on this device, which
/// `AuthScreen` reads once when it appears (#583). Every suite that builds
/// the screen over a [MockAuthBloc] needs it: the getter isn't nullable, so
/// left unstubbed it throws.
void stubProviderSignInAvailability(
  MockAuthBloc bloc, [
  ProviderSignInAvailability availability = const ProviderSignInAvailable(),
]) => when(() => bloc.providerSignInAvailability).thenReturn(availability);

/// A provider sign-in strategy, as the server advertises one (#583).
const kOidcStrategy = OidcStrategy(
  providerId: 'authentik',
  discoveryUrl: 'https://auth.acme.com/.well-known/openid-configuration',
  displayName: 'Authentik',
  authorizationEndpoint: '$testAuthBasePath/sign-in/social',
  appSignInEndpoint: '$testAuthBasePath/app-sign-in/start',
  appTokenEndpoint: '$testAuthBasePath/app-sign-in/token',
);

/// The shared identity with [kOidcStrategy] after its email strategy: a server
/// that offers both ways in.
ServerIdentity testIdentityWithOidc() => testServerIdentity().copyWith(
  strategies: [testEmailAndPasswordStrategy(), kOidcStrategy],
);
