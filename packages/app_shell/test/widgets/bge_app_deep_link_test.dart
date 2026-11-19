import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

/// Maps a link's `bgeServerId` to this device's registration of it.
class _FakeLookup implements KnownServerLookup {
  _FakeLookup(this._ids);

  final Map<String, String> _ids;

  @override
  Future<String?> localServerIdFor(String bgeServerId) async =>
      _ids[bgeServerId];
}

/// A [FakeAuthRepository] whose session check waits on [sessionCheckGate]
/// while one is set, so a freshly mounted auth bloc can be held before its
/// sign-in outcome. A held check reports nothing cached, so the bloc's
/// restore budget never cuts it short.
class _HeldSessionCheckAuthRepository extends FakeAuthRepository {
  _HeldSessionCheckAuthRepository({super.initialSession});

  Completer<void>? sessionCheckGate;

  @override
  Future<AuthResponse?> getCachedSession() async =>
      sessionCheckGate == null ? super.getCachedSession() : null;

  @override
  Future<AuthResponse?> getSession() async {
    final gate = sessionCheckGate;
    if (gate != null) await gate.future;
    return super.getSession();
  }
}

/// An [ActiveServerScope] whose active server a test can switch, as the
/// orchestrator's switch does, or clear, as disconnecting the last connected
/// server does.
class _SwitchableActiveServerScope implements ActiveServerScope {
  _SwitchableActiveServerScope(this._active);

  ActiveServer? _active;
  final _changes = StreamController<ActiveServer?>.broadcast();

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() => _changes.stream;

  void switchTo(ActiveServer next) {
    _active = next;
    _changes.add(next);
  }

  void clear() {
    _active = null;
    _changes.add(null);
  }

  Future<void> close() => _changes.close();
}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockServerContext extends Mock implements ServerContext {}

// `BgeApp` drains the held deep link (#82): when one arrives, and when the
// shell signals authenticated, which is also how bootstrap enters Ready.
void main() {
  const link = ServerDeepLink(
    serverId: 'bge-1',
    location: '/server/bge-1/event/ev-1',
  );
  const eventDetail = '/events/ev-1';

  /// A link for the second server [buildTwoServerCubit] registers.
  const secondServerLink = ServerDeepLink(
    serverId: 'bge-2',
    location: '/server/bge-2/event/ev-1',
  );

  Future<void> noopHydrated(PlatformBootstrap _) async {}

  PendingDeepLinkHolder buildHolder() {
    final holder = PendingDeepLinkHolder();
    addTearDown(holder.dispose);
    return holder;
  }

  /// A cubit whose bootstrap yields [scope], an orchestrator reporting
  /// [activeId] as active, and a lookup over [knownServers].
  AppBootstrapCubit buildCubit(
    ActiveServerScope scope, {
    required String? Function() activeId,
    required Map<String, String> knownServers,
    _MockServerOrchestrator? orchestrator,
  }) {
    final mock = orchestrator ?? _MockServerOrchestrator();
    when(() => mock.activeServerId).thenAnswer((_) => activeId());
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        orchestrator: mock,
        activeServerScope: scope,
        knownServerLookup: _FakeLookup(knownServers),
      ),
      hydratedStorageInitializer: noopHydrated,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// One server, active, registered as `bge-1`.
  AppBootstrapCubit buildSingleServerCubit(FakeAuthRepository repo) {
    final active = buildActiveServer(repo);
    return buildCubit(
      FakeActiveServerScope(active),
      activeId: () => active.serverId,
      knownServers: {'bge-1': active.serverId},
    );
  }

  /// Two servers: `bge-1` active, signed in and connected, backed by
  /// [firstRepo] when given, and `bge-2` registered but disconnected, backed
  /// by [secondRepo]. Connecting `bge-2` makes it active, as the
  /// orchestrator's `connectServer(makeActive: true)` does, and switching
  /// makes the switched-to server active. Disconnecting the active server
  /// leaves none active, as the orchestrator does with no other server
  /// connected to promote.
  ({AppBootstrapCubit cubit, _MockServerOrchestrator orchestrator})
  buildTwoServerCubit(
    FakeAuthRepository secondRepo, {
    FakeAuthRepository? firstRepo,
  }) {
    final first = buildActiveServer(
      firstRepo ?? FakeAuthRepository(initialSession: testAuthResponse()),
    );
    final second = buildActiveServer(secondRepo, serverId: 'server-uuid-2');
    final servers = {first.serverId: first, second.serverId: second};
    final scope = _SwitchableActiveServerScope(first);
    addTearDown(scope.close);
    String? activeId = first.serverId;
    void makeActive(Invocation invocation) {
      activeId = invocation.positionalArguments.single as String;
      scope.switchTo(servers[activeId]!);
    }

    final orchestrator = _MockServerOrchestrator();
    when(() => orchestrator.getContext(any())).thenReturn(null);
    when(
      () => orchestrator.getContext(first.serverId),
    ).thenReturn(_MockServerContext());
    when(
      () => orchestrator.connectServer(
        any(),
        makeActive: any(named: 'makeActive'),
      ),
    ).thenAnswer((invocation) async => makeActive(invocation));
    when(
      () => orchestrator.switchActiveServer(any()),
    ).thenAnswer((invocation) async => makeActive(invocation));
    when(() => orchestrator.disconnectServer(any())).thenAnswer((
      invocation,
    ) async {
      final serverId = invocation.positionalArguments.single as String;
      when(() => orchestrator.getContext(serverId)).thenReturn(null);
      if (activeId != serverId) return;
      activeId = null;
      scope.clear();
    });
    final cubit = buildCubit(
      scope,
      activeId: () => activeId,
      knownServers: {'bge-1': first.serverId, 'bge-2': second.serverId},
      orchestrator: orchestrator,
    );
    return (cubit: cubit, orchestrator: orchestrator);
  }

  Future<void> pumpApp(
    WidgetTester tester,
    AppBootstrapCubit cubit, {
    PendingDeepLinkHolder? holder,
  }) async {
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, pendingDeepLinkHolder: holder),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
  }

  String location(WidgetTester tester) => GoRouter.of(
    tester.element(find.byType(Navigator).first),
  ).routerDelegate.currentConfiguration.uri.toString();

  testWidgets("a link held at a cold start lands on the event's detail "
      'once signed in', (tester) async {
    final holder = buildHolder()..set(link);
    final cubit = buildSingleServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );

    await pumpApp(tester, cubit, holder: holder);

    expect(cubit.state, isA<AppBootstrapReady>());
    expect(location(tester), eventDetail);
    expect(holder.peek, isNull);
  });

  testWidgets('a link arriving while signed in lands', (tester) async {
    final holder = buildHolder();
    final cubit = buildSingleServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    await pumpApp(tester, cubit, holder: holder);
    expect(find.byType(HomeScreen), findsOneWidget);

    holder.set(link);
    await tester.pumpAndSettle();

    expect(location(tester), eventDetail);
    expect(holder.peek, isNull);
  });

  // #126: an app link names no server, and opens on the active one.
  testWidgets('a bge://settings link held at a cold start opens settings '
      'once signed in', (tester) async {
    final result =
        normalizeDeepLink(Uri.parse('bge://settings')) as DeepLinkNormalized;
    final holder = buildHolder()..set(result.link);
    final cubit = buildSingleServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );

    await pumpApp(tester, cubit, holder: holder);

    expect(cubit.state, isA<AppBootstrapReady>());
    expect(location(tester), AppRoutes.settings);
    expect(holder.peek, isNull);
  });

  testWidgets('a bge://settings/export link goes to the export page once '
      'signed in', (tester) async {
    final holder = buildHolder();
    final cubit = buildSingleServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    await pumpApp(tester, cubit, holder: holder);
    expect(find.byType(HomeScreen), findsOneWidget);

    final result = normalizeDeepLink(
      Uri.parse('bge://settings/export'),
    ) as DeepLinkNormalized;
    holder.set(result.link);
    await tester.pumpAndSettle();

    expect(location(tester), AppRoutes.settingsExport);
    expect(holder.peek, isNull);
  });

  testWidgets('a link for a server not added shows the unknown-server '
      'screen', (tester) async {
    final holder = buildHolder();
    final cubit = buildSingleServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    await pumpApp(tester, cubit, holder: holder);

    holder.set(
      const ServerDeepLink(
        serverId: 'bge-unknown',
        location: '/server/bge-unknown/event/ev-1',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(UnknownServerLinkScreen), findsOneWidget);
    expect(location(tester), AppRoutes.deepLinkUnknownServer);
    expect(holder.peek, isNull);
  });

  testWidgets('a link received while signed out waits for sign-in', (
    tester,
  ) async {
    final holder = buildHolder();
    final repo = FakeAuthRepository(); // no session
    final cubit = buildSingleServerCubit(repo);
    await pumpApp(tester, cubit, holder: holder);
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());

    holder.set(link);
    await tester.pumpAndSettle();

    expect(location(tester), AppRoutes.auth);
    expect(holder.peek, link);

    repo.emitAuthState(AuthStateAuthenticated(session: testAuthResponse()));
    await tester.pumpAndSettle();

    expect(cubit.state, isA<AppBootstrapReady>());
    expect(location(tester), eventDetail);
    expect(holder.peek, isNull);
  });

  // The app is already Ready when the switched-to server signs in, so no
  // Ready arrives: only the authenticated signal can land the link.
  testWidgets('a link for a registered server that is not active lands '
      'once that server signs in', (tester) async {
    final holder = buildHolder();
    final (:cubit, :orchestrator) = buildTwoServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    await pumpApp(tester, cubit, holder: holder);
    expect(find.byType(HomeScreen), findsOneWidget);

    holder.set(secondServerLink);
    await tester.pumpAndSettle();

    verify(
      () => orchestrator.connectServer('server-uuid-2', makeActive: true),
    ).called(1);
    expect(cubit.state, isA<AppBootstrapReady>());
    expect(location(tester), eventDetail);
    expect(holder.peek, isNull);
  });

  // #82: a switch that drops the app to sign-in keeps the link for the next
  // Ready.
  testWidgets('a link for a registered server with no session waits on '
      'sign-in after the switch, then lands', (tester) async {
    final holder = buildHolder();
    final secondRepo = FakeAuthRepository(); // no session
    final (:cubit, :orchestrator) = buildTwoServerCubit(secondRepo);
    await pumpApp(tester, cubit, holder: holder);
    expect(find.byType(HomeScreen), findsOneWidget);

    holder.set(secondServerLink);
    await tester.pumpAndSettle();

    verify(
      () => orchestrator.connectServer('server-uuid-2', makeActive: true),
    ).called(1);
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
    expect(location(tester), AppRoutes.auth);
    expect(holder.peek, secondServerLink);

    await secondRepo.signIn(email: 'player@example.com', password: 'pw');
    await tester.pumpAndSettle();

    expect(cubit.state, isA<AppBootstrapReady>());
    expect(location(tester), eventDetail);
    expect(holder.peek, isNull);
    verifyNever(() => orchestrator.switchActiveServer(any()));
    verifyNever(
      () => orchestrator.connectServer(
        any(),
        makeActive: any(named: 'makeActive'),
      ),
    );
  });

  // #985: switched away and back before the auth scope rebuilds, the first
  // server's signed-in bloc stays mounted, so no sign-in outcome follows the
  // switch back for the link to wait on.
  testWidgets('an A → B → A switch inside one frame lands the link for A', (
    tester,
  ) async {
    const firstServerLink = ServerDeepLink(
      serverId: 'bge-1',
      location: '/server/bge-1/event/ev-2',
    );
    final holder = buildHolder();
    final (:cubit, :orchestrator) = buildTwoServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    await pumpApp(tester, cubit, holder: holder);
    expect(find.byType(HomeScreen), findsOneWidget);

    holder.set(secondServerLink);
    // Set back to back, the two links would never switch to B: B's pass
    // finds itself replaced once its lookup answers, and stops. Idling runs
    // the switch to B to completion without building a frame, so the auth
    // scope never rebuilds for B.
    await tester.idle();
    verify(
      () => orchestrator.connectServer('server-uuid-2', makeActive: true),
    ).called(1);
    holder.set(firstServerLink);
    await tester.pumpAndSettle();

    verify(() => orchestrator.switchActiveServer('server-uuid-1')).called(1);
    expect(location(tester), '/events/ev-2');
    expect(holder.peek, isNull);
  });

  // #985: once the scope has rebuilt for another server, switching back
  // mounts a fresh bloc for the first, whose sign-in outcome is unknown
  // again, so the link must wait for it rather than trust the old session.
  testWidgets('a link for a server whose scope was rebuilt waits for its '
      'sign-in again', (tester) async {
    const firstServerLink = ServerDeepLink(
      serverId: 'bge-1',
      location: '/server/bge-1/event/ev-2',
    );
    final firstRepo = _HeldSessionCheckAuthRepository(
      initialSession: testAuthResponse(),
    );
    final secondRepo = _HeldSessionCheckAuthRepository(
      initialSession: testAuthResponse(),
    );
    final holder = buildHolder();
    final (:cubit, :orchestrator) = buildTwoServerCubit(
      secondRepo,
      firstRepo: firstRepo,
    );
    await pumpApp(tester, cubit, holder: holder);
    expect(find.byType(HomeScreen), findsOneWidget);

    // Switched to B, as the server switcher would, and a frame builds B's
    // bloc. Its session check is held, so B is signed in nowhere yet.
    final secondCheck = Completer<void>();
    secondRepo.sessionCheckGate = secondCheck;
    await orchestrator.connectServer('server-uuid-2', makeActive: true);
    // Not pumpAndSettle, here or below: until a session is live on the
    // server switched to, home waits on the splash (#134), which never
    // settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(cubit.state, isA<AppBootstrapReady>());
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    // Back to A for a link: A's bloc is built afresh, its check held too.
    final firstCheck = Completer<void>();
    firstRepo.sessionCheckGate = firstCheck;
    holder.set(firstServerLink);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    verify(() => orchestrator.switchActiveServer('server-uuid-1')).called(1);
    expect(holder.peek, firstServerLink);
    expect(location(tester), isNot('/events/ev-2'));

    firstCheck.complete();
    await tester.pumpAndSettle();

    expect(location(tester), '/events/ev-2');
    expect(holder.peek, isNull);

    secondCheck.complete();
    await tester.pumpAndSettle();
  });

  // #985: with no server active, the auth scope holds no bloc, so the one
  // that was signed in is gone. Making its server active again builds a
  // fresh bloc whose sign-in outcome the link must wait for.
  testWidgets('a link for a server that stopped being active waits for its '
      'sign-in again', (tester) async {
    const firstServerLink = ServerDeepLink(
      serverId: 'bge-1',
      location: '/server/bge-1/event/ev-2',
    );
    final firstRepo = _HeldSessionCheckAuthRepository(
      initialSession: testAuthResponse(),
    );
    final holder = buildHolder();
    final (:cubit, :orchestrator) = buildTwoServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
      firstRepo: firstRepo,
    );
    await pumpApp(tester, cubit, holder: holder);
    expect(find.byType(HomeScreen), findsOneWidget);

    // The active server disconnected with no other to promote, and a frame
    // builds the scope with none active. Nothing signs the app out.
    await orchestrator.disconnectServer('server-uuid-1');
    await tester.pumpAndSettle();
    expect(cubit.orchestrator!.activeServerId, isNull);
    expect(cubit.state, isA<AppBootstrapReady>());

    // A link for it connects it and makes it active again, and its fresh
    // bloc's session check is held.
    final firstCheck = Completer<void>();
    firstRepo.sessionCheckGate = firstCheck;
    holder.set(firstServerLink);
    await tester.pumpAndSettle();

    verify(
      () => orchestrator.connectServer('server-uuid-1', makeActive: true),
    ).called(1);
    expect(holder.peek, firstServerLink);
    expect(location(tester), isNot('/events/ev-2'));

    firstCheck.complete();
    await tester.pumpAndSettle();

    expect(location(tester), '/events/ev-2');
    expect(holder.peek, isNull);
  });

  testWidgets('a link whose switch fails at capacity shows the limit', (
    tester,
  ) async {
    final holder = buildHolder();
    final (:cubit, :orchestrator) = buildTwoServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    when(
      () => orchestrator.connectServer(
        any(),
        makeActive: any(named: 'makeActive'),
      ),
    ).thenAnswer(
      (_) async => throw const ServerCapacityExceededException(
        currentConnected: 3,
        maxCapacity: 5,
      ),
    );
    await pumpApp(tester, cubit, holder: holder);
    final before = location(tester);

    holder.set(secondServerLink);
    await tester.pumpAndSettle();

    // The count differs from the limit, so naming the count fails here.
    expect(
      find.text('This device connects up to 5 servers at once.'),
      findsOneWidget,
    );
    expect(
      find.text('This device connects up to 3 servers at once.'),
      findsNothing,
    );
    expect(location(tester), before);
    expect(holder.peek, isNull);
  });

  testWidgets('with no holder, nothing is wired', (tester) async {
    final cubit = buildSingleServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );

    await pumpApp(tester, cubit);

    expect(tester.takeException(), isNull);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
