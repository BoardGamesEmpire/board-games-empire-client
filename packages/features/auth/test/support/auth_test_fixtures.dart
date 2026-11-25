import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart'
    show Bloc, BlocBase, BlocObserver;
import 'package:flutter_test/flutter_test.dart' show addTearDown;
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

/// Records every error a bloc reports through `onError`, `addError`'s
/// included, from blocs built after it is called. Call it from a `setUp`.
///
/// For a handler that reports an error and then emits a state (#726).
/// `blocTest`'s `errors:` can't pin that: when it is given, an error that
/// escapes the handler ends the test before `expect:` is checked, so a
/// handler stranded on its loading state passes too.
///
/// It wraps whatever `Bloc.observer` is when it is called and puts that back
/// at teardown. That is seldom the default observer here: bloc_test 10.0.0
/// wraps `Bloc.observer` in its own test observer on every `blocTest` and
/// never restores it, so it is usually the chain earlier tests left. The
/// recorder forwards only `onError` to it; its other hooks run
/// `BlocObserver`'s no-op defaults.
List<Object> recordBlocErrors() {
  final errors = <Object>[];
  final previous = Bloc.observer;
  Bloc.observer = _ErrorRecorder(previous, errors.add);
  addTearDown(() => Bloc.observer = previous);
  return errors;
}

final class _ErrorRecorder extends BlocObserver {
  const _ErrorRecorder(this._previous, this._record);

  final BlocObserver _previous;
  final void Function(Object error) _record;

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    _record(error);
    _previous.onError(bloc, error, stackTrace);
  }
}
