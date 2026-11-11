import 'package:models/domain.dart';

/// The auth base path [testServerIdentity] advertises.
const String testAuthBasePath = '/api/auth';

/// The address [testServerIdentity] names as its issuer.
///
/// A suite that hands the identity to code alongside a server address passes
/// this one, so the pair stays the one a real server reports: provider
/// sign-in refuses an issuer that isn't the address it was reached at.
const String testServerUrl = 'https://bge.example.com';

/// The email and password strategy [testServerIdentity] advertises, open for
/// sign-up unless [signUpDisabled].
///
/// [signUpDisabled] also nulls `signUpEndpoint`, so the two stay consistent
/// the way a real server reports them. Shared for the reason
/// [testServerIdentity] is (#409).
EmailAndPasswordStrategy testEmailAndPasswordStrategy({
  bool signUpDisabled = false,
}) => EmailAndPasswordStrategy(
  signUpDisabled: signUpDisabled,
  signInEndpoint: '$testAuthBasePath/sign-in/email',
  signUpEndpoint: signUpDisabled ? null : '$testAuthBasePath/sign-up/email',
);

/// The `ServerIdentity` suites register and sign in against.
///
/// Shared (#409): suites used to hand-roll their own copies, which drifted;
/// they now share this one and vary it with `copyWith`, for example
/// `testServerIdentity().copyWith(serverId: 'other')`.
ServerIdentity testServerIdentity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: testServerUrl,
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$testAuthBasePath/device',
  authBasePath: testAuthBasePath,
  sessionEndpoint: '$testAuthBasePath/get-session',
  signOutEndpoint: '$testAuthBasePath/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [testEmailAndPasswordStrategy()],
);
