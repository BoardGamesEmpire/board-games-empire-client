import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:server_onboarding/server_onboarding.dart';

/// Pins the `/server-add` composition guard (#189).
///
/// The seam under test is the rendered route, not the private builder: a
/// root container is composed with some subset of the server-add
/// dependency set, `BgeApp` is pumped in [AppBootstrapNeedsServer] (the
/// only state whose redirect lands on `/server-add`), and the test asserts
/// which screen comes back. A partial composition must degrade to
/// [ShellPlaceholderScreen] rather than throw at navigation time.
class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _FakeServerOrchestrator extends Mock implements ServerOrchestrator {}

/// Returns [identity] when the flow actually runs discovery. Most tests
/// never submit the form, so the default is a benign stand-in rather than a
/// throw — a throw here would surface as a bloc failure state and mask
/// whatever the test was really asserting.
class _FakeWellKnownClient implements WellKnownClient {
  _FakeWellKnownClient([ServerIdentity? identity])
    : identity = identity ?? _compatibleIdentity;

  final ServerIdentity identity;

  @override
  Future<ServerIdentity> fetchIdentity(String serverUrl) async => identity;
}

/// Declares no client-version bounds, so negotiation passes against
/// [BuildInfo.unknown] (whose `0.0.0` would fail any declared minimum).
const _compatibleIdentity = ServerIdentity(
  wellKnownSchemaVersion: 1,
  serverId: 'server-uuid',
  name: 'Home BGE',
  issuer: 'https://bge.example.com',
  deviceAuthorizationEndpoint: '/api/auth/device/code',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
);

class _FakeConnectivityService implements ConnectivityService {
  @override
  ConnectivityState get current => ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() =>
      Stream<ConnectivityState>.value(ConnectivityState.online);
}

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  /// Builds a root container holding the server-add dependency set, minus
  /// whichever members are switched off — the shape of a partial
  /// composition.
  DependencyContainerImpl composeContainer({
    bool wellKnownClient = true,
    bool versionNegotiator = true,
    bool connectivityService = true,
    bool buildInfo = true,
  }) {
    final container = DependencyContainerImpl();
    addTearDown(container.dispose);
    // Registration *modes* mirror the production root modules, not just
    // the type set: WellKnownClient, VersionNegotiator and
    // ConnectivityService are lazy singletons there
    // (native_root_module.dart, web_root_module.dart) and BuildInfo is
    // eager. Registering everything eagerly here would make
    // `container.get` a map lookup in tests where production runs a
    // factory for the first time, hiding the registered-but-unresolvable
    // case entirely.
    if (wellKnownClient) {
      container.registerLazySingleton<WellKnownClient>(
        _FakeWellKnownClient.new,
      );
    }
    if (versionNegotiator) {
      // The real one: pure, synchronous, no I/O — a fake would only
      // restate it.
      container.registerLazySingleton<VersionNegotiator>(
        VersionNegotiatorImpl.new,
      );
    }
    if (connectivityService) {
      container.registerLazySingleton<ConnectivityService>(
        _FakeConnectivityService.new,
      );
    }
    if (buildInfo) {
      container.registerSingleton<BuildInfo>(BuildInfo.unknown);
    }
    return container;
  }

  /// Pumps [BgeApp] in [AppBootstrapNeedsServer], whose redirect pins every
  /// location to `/server-add`, so settling lands on the route under test.
  Future<_FakeServerOrchestrator?> pumpServerAdd(
    WidgetTester tester, {
    DependencyContainer? rootContainer,
    bool withOrchestrator = true,
  }) async {
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapNeedsServer(),
    );
    final orchestrator = withOrchestrator ? _FakeServerOrchestrator() : null;
    when(() => cubit.orchestrator).thenReturn(orchestrator);
    when(() => cubit.activeServerScope).thenReturn(null);

    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, rootContainer: rootContainer),
    );
    await tester.pumpAndSettle();
    return orchestrator;
  }

  void expectPlaceholder(WidgetTester tester) {
    expect(tester.takeException(), isNull);
    expect(find.byType(ShellPlaceholderScreen), findsOneWidget);
    expect(find.byType(ServerAddScreen), findsNothing);
  }

  group('/server-add composition guard (#189)', () {
    testWidgets('renders the real flow when the composition is complete', (
      tester,
    ) async {
      await pumpServerAdd(tester, rootContainer: composeContainer());

      expect(tester.takeException(), isNull);
      expect(find.byType(ServerAddScreen), findsOneWidget);
      expect(find.byType(ShellPlaceholderScreen), findsNothing);
    });

    testWidgets('renders the placeholder when ConnectivityService is absent '
        'but WellKnownClient is registered', (tester) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(connectivityService: false),
      );

      expectPlaceholder(tester);
    });

    testWidgets('renders the placeholder when VersionNegotiator is absent '
        'but WellKnownClient is registered', (tester) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(versionNegotiator: false),
      );

      expectPlaceholder(tester);
    });

    testWidgets('renders the placeholder when BuildInfo is absent but '
        'WellKnownClient is registered', (tester) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(buildInfo: false),
      );

      expectPlaceholder(tester);
    });

    testWidgets('renders the placeholder when WellKnownClient is absent', (
      tester,
    ) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(wellKnownClient: false),
      );

      expectPlaceholder(tester);
    });

    testWidgets('renders the placeholder when no orchestrator is published, '
        'even with every service registered', (tester) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(),
        withOrchestrator: false,
      );

      expectPlaceholder(tester);
    });

    testWidgets('renders the placeholder when there is no root container', (
      tester,
    ) async {
      await pumpServerAdd(tester);

      expectPlaceholder(tester);
    });

    testWidgets('renders the placeholder for the web composition — no '
        'WellKnownClient and no orchestrator', (tester) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(wellKnownClient: false),
        withOrchestrator: false,
      );

      expectPlaceholder(tester);
    });
  });

  group('/server-add success bridge (#36)', () {
    setUpAll(() {
      registerFallbackValue(_compatibleIdentity);
    });

    testWidgets('a successful add notifies the bootstrap cubit, so the '
        'redirect can leave /server-add', (tester) async {
      final orchestrator = await pumpServerAdd(
        tester,
        rootContainer: composeContainer(),
      );
      when(
        () => orchestrator!.addAndActivateServer(
          displayName: any(named: 'displayName'),
          serverUrl: any(named: 'serverUrl'),
          bgeServerId: any(named: 'bgeServerId'),
          identity: any(named: 'identity'),
        ),
      ).thenAnswer((_) async => 'local-server-id');

      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'https://bge.example.com',
      );
      await tester.ensureVisible(find.byKey(ServerAddForm.submitButtonKey));
      await tester.tap(find.byKey(ServerAddForm.submitButtonKey));
      await tester.pumpAndSettle();

      // The BlocListener translating ServerOnboardingSucceeded into the
      // cubit signal is the only thing that lets the router advance; the
      // cubit never leaves AppBootstrapNeedsServer without it.
      verify(() => cubit.onServerRegistered()).called(1);
    });

    testWidgets('a failed add leaves the cubit untouched', (tester) async {
      final orchestrator = await pumpServerAdd(
        tester,
        rootContainer: composeContainer(),
      );
      when(
        () => orchestrator!.addAndActivateServer(
          displayName: any(named: 'displayName'),
          serverUrl: any(named: 'serverUrl'),
          bgeServerId: any(named: 'bgeServerId'),
          identity: any(named: 'identity'),
        ),
      ).thenThrow(StateError('capacity'));

      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'https://bge.example.com',
      );
      await tester.ensureVisible(find.byKey(ServerAddForm.submitButtonKey));
      await tester.tap(find.byKey(ServerAddForm.submitButtonKey));
      await tester.pumpAndSettle();

      verifyNever(() => cubit.onServerRegistered());
    });
  });

  group('/server-add guard diagnostics (#189)', () {
    late List<LogRecord> records;

    setUp(() {
      records = [];
      // Deliberately no `Logger.root.level` override: SEVERE already
      // clears logging's default INFO threshold, and raising the level
      // here would leak into every group appended after this one.
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
    });

    /// Scoped to this builder's logger — a SEVERE from any other
    /// collaborator would otherwise turn `single` into a spurious failure.
    List<LogRecord> errors() => records
        .where(
          (r) => r.level >= Level.SEVERE && r.loggerName == 'bge.shell.router',
        )
        .toList();

    testWidgets('logs an error naming the missing service — reaching this '
        'builder at all means the app is pinned to /server-add', (
      tester,
    ) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(connectivityService: false),
      );

      expect(errors(), hasLength(1));
      expect(errors().single.message, contains('ConnectivityService'));
      expect(errors().single.message, isNot(contains('WellKnownClient')));
    });

    testWidgets('names the orchestrator when bootstrap published none', (
      tester,
    ) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(),
        withOrchestrator: false,
      );

      expect(errors(), hasLength(1));
      expect(errors().single.message, contains('ServerOrchestrator'));
    });

    testWidgets('logs nothing when the composition is complete', (
      tester,
    ) async {
      await pumpServerAdd(tester, rootContainer: composeContainer());

      expect(errors(), isEmpty);
    });

    testWidgets('names every absent member, not just the first — services '
        'and the orchestrator together', (tester) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(
          wellKnownClient: false,
          buildInfo: false,
        ),
        withOrchestrator: false,
      );

      expect(errors(), hasLength(1));
      final message = errors().single.message;
      expect(message, contains('WellKnownClient'));
      expect(message, contains('BuildInfo'));
      expect(message, contains('ServerOrchestrator'));
      expect(message, isNot(contains('VersionNegotiator')));
      expect(message, isNot(contains('ConnectivityService')));
    });

    testWidgets('names every absent member when there is no container at all', (
      tester,
    ) async {
      await pumpServerAdd(tester, withOrchestrator: false);

      expect(errors(), hasLength(1));
      final message = errors().single.message;
      for (final member in const [
        'WellKnownClient',
        'VersionNegotiator',
        'ConnectivityService',
        'BuildInfo',
        'ServerOrchestrator',
      ]) {
        expect(message, contains(member));
      }
    });

    testWidgets('carries the absent members as structured context, not only '
        'in the message text', (tester) async {
      await pumpServerAdd(
        tester,
        rootContainer: composeContainer(connectivityService: false),
      );

      // Structured consumers (the breadcrumb ring, JSON sinks) read the
      // context off LogRecord.object — never off the rendered message —
      // so a message-only assertion would not notice it disappearing.
      final record = errors().single;
      expect(record.object, isA<ContextLogMessage>());
      expect(
        (record.object! as ContextLogMessage).context,
        containsPair('missing', ['ConnectivityService']),
      );
    });
  });
}
