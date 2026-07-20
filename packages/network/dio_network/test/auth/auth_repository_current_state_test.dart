import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:interfaces/repositories.dart';

const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'bge-uuid-1',
  issuer: 'https://bge.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

/// #97: [AuthRepositoryImpl.currentAuthState] is the synchronous mirror
/// of the in-memory state [watchAuthState] replays on subscribe — the
/// seam the feedback target resolver reads per submit/drain.
void main() {
  group('AuthRepositoryImpl.currentAuthState', () {
    test('starts Unknown and matches the value watchAuthState '
        'replays', () async {
      final repository = AuthRepositoryImpl(
        identity: _identity(),
        tokenStorage: TokenStorageService(serverId: 'bge-uuid-1'),
        dio: Dio(),
      );
      addTearDown(repository.onDispose);

      expect(repository.currentAuthState, isA<AuthStateUnknown>());
      expect(
        await repository.watchAuthState().first,
        repository.currentAuthState,
      );
    });
  });
}
