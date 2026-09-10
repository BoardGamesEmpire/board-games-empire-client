import 'package:models/domain.dart';

/// The `ServerIdentity` the `registerServerNetworkWeb` suites register with.
///
/// Web has no MetaDB and no persisted `ServerConfig`: the browser can only
/// talk to the origin in the address bar, and the identity is fetched from
/// that origin's well-known document at runtime — so the installer takes a
/// [ServerIdentity] directly, and constructing a synthetic `ServerConfig` just
/// to carry one is the wart that signature removes.
///
/// Shared rather than restated per suite (#125): `ServerIdentity` is a
/// required-field-heavy model, so three copies meant three edits to keep the
/// package compiling whenever a field was added, and nothing stopped them
/// drifting into asserting against different origins.
ServerIdentity testServerIdentity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://bge.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$testAuthBasePath/device',
  authBasePath: testAuthBasePath,
  sessionEndpoint: '$testAuthBasePath/get-session',
  signOutEndpoint: '$testAuthBasePath/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$testAuthBasePath/sign-in/email',
      signUpEndpoint: '$testAuthBasePath/sign-up/email',
    ),
  ],
);

/// The auth base path [testServerIdentity] advertises.
const String testAuthBasePath = '/api/auth';
