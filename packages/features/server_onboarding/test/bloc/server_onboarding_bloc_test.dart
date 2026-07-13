import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_onboarding/server_onboarding.dart';

class _MockWellKnownClient extends Mock implements WellKnownClient {}

class _MockVersionNegotiator extends Mock implements VersionNegotiator {}

class _MockConnectivityService extends Mock implements ConnectivityService {}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

const _kBuildInfo = BuildInfo(
  version: '1.2.3',
  buildNumber: '42',
  appName: 'BGE',
  packageName: 'com.bge.app',
);

const _kUrl = 'https://bge.example.com';

ServerIdentity _identity({String name = 'Home BGE'}) => ServerIdentity(
  wellKnownSchemaVersion: 1,
  serverId: '550e8400-e29b-41d4-a716-446655440000',
  name: name,
  issuer: _kUrl,
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
);

void main() {
  late _MockWellKnownClient wellKnown;
  late _MockVersionNegotiator negotiator;
  late _MockConnectivityService connectivity;
  late _MockServerOrchestrator orchestrator;

  setUpAll(() {
    registerFallbackValue(_kBuildInfo);
    registerFallbackValue(_identity());
  });

  setUp(() {
    wellKnown = _MockWellKnownClient();
    negotiator = _MockVersionNegotiator();
    connectivity = _MockConnectivityService();
    orchestrator = _MockServerOrchestrator();

    when(() => connectivity.current).thenReturn(ConnectivityState.online);
    when(
      () => wellKnown.fetchIdentity(any()),
    ).thenAnswer((_) async => _identity());
    when(
      () => negotiator.negotiate(
        buildInfo: any(named: 'buildInfo'),
        identity: any(named: 'identity'),
      ),
    ).thenReturn(const VersionCompatible());
    when(
      () => orchestrator.addAndActivateServer(
        displayName: any(named: 'displayName'),
        serverUrl: any(named: 'serverUrl'),
        bgeServerId: any(named: 'bgeServerId'),
        identity: any(named: 'identity'),
      ),
    ).thenAnswer((_) async => 'local-id-1');
  });

  ServerOnboardingBloc build() => ServerOnboardingBloc(
    wellKnownClient: wellKnown,
    versionNegotiator: negotiator,
    connectivityService: connectivity,
    buildInfo: _kBuildInfo,
    orchestrator: orchestrator,
  );

  group('ServerOnboardingBloc', () {
    test('starts idle', () {
      final bloc = build();
      addTearDown(bloc.close);
      expect(bloc.state, const ServerOnboardingIdle());
    });

    group('local URL validation', () {
      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'invalid URL fails without touching the network',
        build: build,
        act: (bloc) =>
            bloc.add(const ServerOnboardingSubmitted(url: 'ftp://x.example')),
        expect: () => const [
          ServerOnboardingInvalidUrl(ServerUrlError.unsupportedScheme),
        ],
        verify: (_) => verifyNever(() => wellKnown.fetchIdentity(any())),
      );
    });

    group('offline fast-fail (#9)', () {
      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'surfaces offline before any fetch',
        build: build,
        setUp: () => when(
          () => connectivity.current,
        ).thenReturn(ConnectivityState.offline),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingOffline(),
        ],
        verify: (_) => verifyNever(() => wellKnown.fetchIdentity(any())),
      );
    });

    group('discovery failures', () {
      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        '404 → not a BGE server',
        build: build,
        setUp: () => when(() => wellKnown.fetchIdentity(any())).thenThrow(
          const WellKnownNotFoundException(serverUrl: _kUrl, message: '404'),
        ),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingNotBgeServer(),
        ],
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'network failure → unreachable',
        build: build,
        setUp: () => when(() => wellKnown.fetchIdentity(any())).thenThrow(
          const WellKnownUnreachableException(
            serverUrl: _kUrl,
            message: 'timeout',
          ),
        ),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingUnreachable(),
        ],
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'bad body → invalid response',
        build: build,
        setUp: () => when(() => wellKnown.fetchIdentity(any())).thenThrow(
          const WellKnownInvalidResponseException(
            serverUrl: _kUrl,
            message: 'parse',
            statusCode: 200,
          ),
        ),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingInvalidResponse(),
        ],
      );
    });

    group('version negotiation (#13) — a mismatch never persists', () {
      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'clientTooOld surfaces payload and never reaches the orchestrator',
        build: build,
        setUp: () =>
            when(
              () => negotiator.negotiate(
                buildInfo: any(named: 'buildInfo'),
                identity: any(named: 'identity'),
              ),
            ).thenReturn(
              const ClientTooOld(
                clientVersion: '1.2.3',
                requiredMinimum: '2.0.0',
              ),
            ),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingClientTooOld(
            clientVersion: '1.2.3',
            requiredMinimum: '2.0.0',
          ),
        ],
        verify: (_) => verifyNever(
          () => orchestrator.addAndActivateServer(
            displayName: any(named: 'displayName'),
            serverUrl: any(named: 'serverUrl'),
            bgeServerId: any(named: 'bgeServerId'),
            identity: any(named: 'identity'),
          ),
        ),
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'clientTooNew surfaces payload and never persists',
        build: build,
        setUp: () =>
            when(
              () => negotiator.negotiate(
                buildInfo: any(named: 'buildInfo'),
                identity: any(named: 'identity'),
              ),
            ).thenReturn(
              const ClientTooNew(
                clientVersion: '1.2.3',
                supportedMaximum: '1.0.0',
              ),
            ),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingClientTooNew(
            clientVersion: '1.2.3',
            supportedMaximum: '1.0.0',
          ),
        ],
        verify: (_) => verifyNever(
          () => orchestrator.addAndActivateServer(
            displayName: any(named: 'displayName'),
            serverUrl: any(named: 'serverUrl'),
            bgeServerId: any(named: 'bgeServerId'),
            identity: any(named: 'identity'),
          ),
        ),
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'schemaTooNew never persists',
        build: build,
        setUp: () => when(
          () => negotiator.negotiate(
            buildInfo: any(named: 'buildInfo'),
            identity: any(named: 'identity'),
          ),
        ).thenReturn(const SchemaTooNew(serverSchemaVersion: 9)),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingSchemaTooNew(),
        ],
        verify: (_) => verifyNever(
          () => orchestrator.addAndActivateServer(
            displayName: any(named: 'displayName'),
            serverUrl: any(named: 'serverUrl'),
            bgeServerId: any(named: 'bgeServerId'),
            identity: any(named: 'identity'),
          ),
        ),
      );
    });

    group('persist + activate', () {
      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'succeeds with the normalized URL and the server-advertised name '
        'when the alias is blank',
        build: build,
        act: (bloc) => bloc.add(
          const ServerOnboardingSubmitted(url: 'bge.example.com/', alias: ' '),
        ),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingSucceeded(
            serverId: 'local-id-1',
            displayName: 'Home BGE',
          ),
        ],
        verify: (_) => verify(
          () => orchestrator.addAndActivateServer(
            displayName: 'Home BGE',
            serverUrl: 'https://bge.example.com',
            bgeServerId: '550e8400-e29b-41d4-a716-446655440000',
            identity: any(named: 'identity'),
          ),
        ).called(1),
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'a non-blank alias wins over the advertised name',
        build: build,
        act: (bloc) => bloc.add(
          const ServerOnboardingSubmitted(url: _kUrl, alias: 'My Server'),
        ),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingSucceeded(
            serverId: 'local-id-1',
            displayName: 'My Server',
          ),
        ],
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'duplicate registration maps to its own failure',
        build: build,
        setUp: () => when(
          () => orchestrator.addAndActivateServer(
            displayName: any(named: 'displayName'),
            serverUrl: any(named: 'serverUrl'),
            bgeServerId: any(named: 'bgeServerId'),
            identity: any(named: 'identity'),
          ),
        ).thenThrow(const DuplicateServerException(_kUrl)),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingDuplicate(),
        ],
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'capacity maps to its own failure',
        build: build,
        setUp: () =>
            when(
              () => orchestrator.addAndActivateServer(
                displayName: any(named: 'displayName'),
                serverUrl: any(named: 'serverUrl'),
                bgeServerId: any(named: 'bgeServerId'),
                identity: any(named: 'identity'),
              ),
            ).thenThrow(
              const ServerCapacityExceededException(
                currentConnected: 5,
                maxCapacity: 5,
              ),
            ),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => const [
          ServerOnboardingInProgress(),
          ServerOnboardingCapacityExceeded(),
        ],
      );

      blocTest<ServerOnboardingBloc, ServerOnboardingState>(
        'anything unanticipated maps to the fallback failure',
        build: build,
        setUp: () => when(
          () => orchestrator.addAndActivateServer(
            displayName: any(named: 'displayName'),
            serverUrl: any(named: 'serverUrl'),
            bgeServerId: any(named: 'bgeServerId'),
            identity: any(named: 'identity'),
          ),
        ).thenThrow(StateError('activation blew up')),
        act: (bloc) => bloc.add(const ServerOnboardingSubmitted(url: _kUrl)),
        expect: () => [
          const ServerOnboardingInProgress(),
          isA<ServerOnboardingUnexpectedFailure>(),
        ],
      );
    });
  });
}
