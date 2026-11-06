// The origin the browser suites boot against: its address, its well-known
// client and the identity that client answers with. Shared so that the
// bootstrap test (#325) and the composed session suite (#369) name the same
// origin and make server ids the same way.

import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart' show WellKnownClient;

/// The origin the suites fake. `.invalid` never resolves, so a request that
/// escaped the scripted transport fails rather than reaching a host.
const String kWebTestOrigin = 'https://bge.test.invalid';

/// A well-known client for a suite to answer the discovery fetch with, in
/// place of the same-origin one the bootstrap would build.
class MockWellKnownClient extends Mock implements WellKnownClient {}

/// Counts the server ids this run has handed out; see [freshIdentity].
var _serverSeq = 0;

/// [kWebTestOrigin]'s discovery document, with email and password sign-in,
/// under a server id no earlier test or run has used, starting [prefix].
///
/// `_identity` in `web_network/test/auth/web_auth_repository_impl_test.dart`,
/// with the server id made here and the suites' origin as its issuer.
///
/// Fresh per call because the web database and the drain's Web Lock are named
/// by the server id, and the browser's IndexedDB outlives the test that
/// opened it, so a shared id would leak rows between tests.
///
/// A counter AND a timestamp, because neither alone is enough. On the web
/// `DateTime.now()` is a JavaScript `Date`, with millisecond resolution, so
/// `microsecondsSinceEpoch` ends in `000` and two calls landing in the same
/// millisecond would reopen one database; the counter is what makes that
/// impossible rather than merely unlikely. The timestamp is what keeps a
/// later run off the databases this one leaves behind, which a counter
/// restarting at zero would walk straight back into.
ServerIdentity freshIdentity(String prefix) => ServerIdentity(
  serverId: '$prefix-${DateTime.now().microsecondsSinceEpoch}-${++_serverSeq}',
  issuer: kWebTestOrigin,
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '/api/auth/sign-in/email',
      signUpEndpoint: '/api/auth/sign-up/email',
    ),
  ],
);

/// A [MockWellKnownClient] that answers every fetch with [identity].
MockWellKnownClient wellKnownAnswering(ServerIdentity identity) {
  final client = MockWellKnownClient();
  when(() => client.fetchIdentity(any())).thenAnswer((_) async => identity);
  return client;
}
