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

/// An [ActiveServerScope] whose active server a test can switch, as the
/// orchestrator's switch does.
class _SwitchableActiveServerScope implements ActiveServerScope {
  _SwitchableActiveServerScope(this._active);

  ActiveServer _active;
  final _changes = StreamController<ActiveServer?>.broadcast();

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() => _changes.stream;

  void switchTo(ActiveServer next) {
    _active = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

// `BgeApp` drains the held deep link (#82): when one arrives, and when the
// shell signals authenticated, which is also how bootstrap enters Ready.
void main() {
  const link = NormalizedDeepLink(
    serverId: 'bge-1',
    location: '/server/bge-1/event/ev-1',
  );
  const eventDetail = '/events/ev-1';

  /// A link for the second server [buildTwoServerCubit] registers.
  const secondServerLink = NormalizedDeepLink(
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
    required String Function() activeId,
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

  /// Two servers: `bge-1` active and signed in, and `bge-2` registered but
  /// disconnected, backed by [secondRepo]. Connecting `bge-2` makes it
  /// active, as the orchestrator's `connectServer(makeActive: true)` does.
  ({AppBootstrapCubit cubit, _MockServerOrchestrator orchestrator})
  buildTwoServerCubit(FakeAuthRepository secondRepo) {
    final first = buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    final second = buildActiveServer(secondRepo, serverId: 'server-uuid-2');
    final scope = _SwitchableActiveServerScope(first);
    addTearDown(scope.close);
    var activeId = first.serverId;
    final orchestrator = _MockServerOrchestrator();
    when(() => orchestrator.getContext(any())).thenReturn(null);
    when(
      () => orchestrator.connectServer(
        any(),
        makeActive: any(named: 'makeActive'),
      ),
    ).thenAnswer((invocation) async {
      activeId = invocation.positionalArguments.single as String;
      scope.switchTo(second);
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

  testWidgets('a link for a server not added shows the unknown-server '
      'screen', (tester) async {
    final holder = buildHolder();
    final cubit = buildSingleServerCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    await pumpApp(tester, cubit, holder: holder);

    holder.set(
      const NormalizedDeepLink(
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
