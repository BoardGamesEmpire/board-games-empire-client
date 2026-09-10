// The seam #125 rests on, and the only test that drives it: web's hydrate
// installer resolving an **origin-scope** `HouseholdRemoteDataSource` from
// inside the **user-session scope**, through the container view
// `bootstrapWebServerScope` hands out.
//
// Why it needs its own suite. Registration is pinned in `web_network`
// (`register_server_network_web_household_test.dart`), and the installer list's
// membership and order in `web_user_scope_installers_test.dart` — but neither
// runs the installer against a container assembled the way production
// assembles one. That matters more here than it would elsewhere, because
// `HouseholdHydrateInstaller.install` turns an unresolvable remote into a
// `return` and a debug log (deliberately: a throw there converges to a
// sign-out). So a regression in `WebServerScopeContainer`'s or
// `UserScopeHost`'s fall-through would not fail anything — it would ship as a
// household list that is silently local-only forever.
//
// VM, not browser, and with a mock repository: what is under test is the
// *resolution path*, which needs no database. Driving the same drain over the
// real drift/wasm database in a browser is #369.
@TestOn('vm')
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:web_network/web_network.dart';

const _kOrigin = 'https://bge.example.com';

class _MockWellKnownClient extends Mock implements WellKnownClient {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

/// Registers a [HouseholdRepository] into the **user** scope, standing in for
/// `UserSessionScopeInstaller` without needing a database.
///
/// Production registers it exactly here, which is the arrangement under test:
/// the repository comes from the user scope and the remote from the origin
/// scope, and the hydrate installer has to see both at once.
class _RepositoryInstaller implements UserScopeInstaller {
  const _RepositoryInstaller(this.repository);

  final HouseholdRepository repository;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async => container.registerSingleton<HouseholdRepository>(repository);
}

/// One page of households, served to whatever Dio it is installed on.
class _CannedTransport implements HttpClientAdapter {
  _CannedTransport(this.body);

  final String body;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// An empty page: a complete set with nothing in it.
///
/// Deliberately empty, as the installer's own suite serves an empty page for
/// the same reason — rows would only exercise the hydrator's cache writes,
/// which are pinned where the hydrator is. What this suite needs from the
/// response is that the request happened at all.
const _kEmptyPage =
    '{"households":[],"pagination":{"page":1,"limit":100,"total":0,'
    '"totalPages":0,"hasMore":false}}';

ServerIdentity _identity() => const ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: _kOrigin,
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '/api/auth/sign-in/email',
      signUpEndpoint: '/api/auth/sign-up/email',
    ),
  ],
);

void main() {
  late _MockWellKnownClient wellKnown;
  late _MockHouseholdRepository repository;
  late _CannedTransport transport;
  ActiveServerScope? scope;

  setUp(() {
    wellKnown = _MockWellKnownClient();
    repository = _MockHouseholdRepository();
    transport = _CannedTransport(_kEmptyPage);
    scope = null;

    when(() => wellKnown.fetchIdentity(any()))
        .thenAnswer((_) async => _identity());
  });

  tearDown(() async => scope?.active?.container.dispose());

  /// Boots the origin scope the way production does, then activates a
  /// session over the real installer order — the repository tier first, the
  /// hydrate installer after it.
  Future<DependencyContainer> signIn() async {
    scope = await bootstrapWebServerScope(
      wellKnownClient: wellKnown,
      originProvider: () => _kOrigin,
      userInstallers: [
        _RepositoryInstaller(repository),
        const HouseholdHydrateInstaller(),
      ],
    );
    final container = scope!.active!.container;
    // The transport under the Dio `registerServerNetworkWeb` registered, so
    // the hydrate reaches a canned page instead of the network.
    container.get<Dio>().httpClientAdapter = transport;
    await container.get<UserSessionScope>().activate('user-a');
    return container;
  }

  test('the hydrate installer resolves the origin-scope household client from '
      'inside the user session, so the drain runs', () async {
    final container = await signIn();

    // The status is the observable proof the guard did NOT take its
    // missing-client early return: where the remote is unreachable, nothing
    // is registered at all.
    expect(container.isRegistered<HouseholdHydrationStatus>(), isTrue);

    final status = container.get<HouseholdHydrationStatus>();
    await status.watch().firstWhere(
      (state) => state == HouseholdHydrationState.refreshed,
    );

    // And the drain really went through that remote, not merely resolved it:
    // one request, over the Dio the origin scope registered.
    expect(transport.requests, 1);
  });

  test('the retry the screens press is registered in the same scope', () async {
    final container = await signIn();

    expect(container.isRegistered<HouseholdRefresher>(), isTrue);
  });
}
