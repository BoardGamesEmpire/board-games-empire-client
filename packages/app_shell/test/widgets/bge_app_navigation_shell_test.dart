import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/widgets/offline_strip_host.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:events/events.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:network_interface/network_interface.dart';
import 'package:sync_queue/sync_queue.dart' show SyncQueueDrain, SyncStatusLine;
import 'package:ui/ui.dart' show BgeOfflineStrip, BgePage, BgeSyncStatusScope;

import '../support/active_server_fakes.dart';
import '../support/fake_connectivity.dart';
import '../support/fake_platform_bootstrap.dart';
import '../support/navigation.dart';
import '../support/settings_storage.dart';
import '../support/stub_feedback_service.dart';

/// A collection cache holding nothing, whose watch stays open, as Drift's
/// does.
class _Collection implements GameCollectionRepository {
  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() =>
      Stream.multi((stream) => stream.add(const []));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A server with no games, and none to draw at random.
class _Games implements GamesRemoteDataSource {
  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
    GameSort sort = GameSort.title,
  }) async => PaginatedResult(
    items: const [],
    meta: PaginationMeta(
      page: 1,
      limit: limit,
      total: 0,
      totalPages: 1,
      hasMore: false,
    ),
  );

  @override
  Future<List<GameSummary>> fetchRandom({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// An event cache holding nothing, for the session and for any household.
class _Events implements EventRepository {
  @override
  Stream<List<EventListItem>> watchAttendingEventListItems() =>
      Stream.multi((stream) => stream.add(const []));

  @override
  Stream<List<EventListItem>> watchHouseholdEventListItems(
    String householdId,
  ) => Stream.multi((stream) => stream.add(const []));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The server's DataGateway client, which offers the admin dashboard its
/// DataGateway section (#684). Nothing here reads through it.
class _DataGateways implements DataGatewayRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// What a create sends through. Nothing here sends.
class _Sender implements SyncOperationSender {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The session's sync queue, with [waiting] changes outstanding and none
/// stuck, whose watches stay open, as Drift's do (#47). A watch reads
/// [waiting] as it starts.
class _Queue implements SyncQueueRepository {
  _Queue({this.waiting = 0});

  int waiting;

  @override
  Stream<int> watchPendingCount() =>
      Stream.multi((stream) => stream.add(waiting));

  @override
  Stream<List<SyncQueueEntry>> watchStuckEntries() =>
      Stream.multi((stream) => stream.add(const []));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// What a retry of a stuck change goes through. Nothing here retries.
class _Drain implements SyncQueueDrain {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockUserRemote extends Mock implements UserRemoteDataSource {}

/// A user scope that holds whoever the shell last activated, and waits on
/// [hold] for a user, as a real scope waits on its installers.
class _UserSessionScope implements UserSessionScope {
  _UserSessionScope({this.hold});

  final Future<void>? Function(String userId)? hold;

  @override
  String? activeUserId;

  @override
  Future<void> activate(String userId) async {
    await hold?.call(userId);
    activeUserId = userId;
  }

  @override
  Future<void> deactivate() async => activeUserId = null;
}

AuthResponse _sessionOf(String id, String username) => testAuthResponse()
    .copyWith(token: null)
    .copyWith
    .user(id: id, username: username, email: '$id@example.com');

ServerConfig _server(String displayName) => ServerConfig(
  id: 'local-$displayName',
  displayName: displayName,
  serverUrl: testServerUrl,
  connectionState: ConnectionState.active,
  bgeServerId: 'bge-$displayName',
  cachedIdentity: testServerIdentity(),
  lastIdentityFetchedAt: DateTime.utc(2026, 10, 20),
);

/// `BgeApp` puts every signed-in page in the navigation shell (#414): the
/// destinations the session can reach on a bar or a rail, the rest of the
/// menu in its drawer, on every screen rather than home's alone.
///
/// The shell's own behaviour is pinned in `navigation_shell_test.dart`. What
/// only this file can check is what the app hands it: which destinations a
/// session offers, which entries its menu holds, and when there is no
/// shell at all.
void main() {
  /// A signed-in session on a server offering a collection, events and,
  /// unless [games] is false, the games catalog.
  ActiveServer session({
    FakeAuthRepository? auth,
    bool games = true,
    CallerAccessRepository? access,
    DataGatewayRemoteDataSource? dataGateways,
    UserSessionScope? userSessionScope,
    HouseholdRepository? households,
    SyncOperationSender? sender,
    UserRemoteDataSource? users,
    SyncQueueRepository? queue,
    SyncQueueDrain? drain,
  }) => buildActiveServer(
    auth ?? FakeAuthRepository(initialSession: testAuthResponse()),
    gameCollectionRepository: _Collection(),
    gamesRemoteDataSource: games ? _Games() : null,
    eventRepository: _Events(),
    callerAccess: access,
    dataGatewayRemoteDataSource: dataGateways,
    userSessionScope: userSessionScope,
    householdRepository: households,
    syncOperationSender: sender,
    userRemoteDataSource: users,
    syncQueueRepository: queue,
    syncQueueDrain: drain,
  );

  /// A household cache holding nothing.
  HouseholdRepository noHouseholds() {
    final households = _MockHouseholdRepository();
    when(households.watchHouseholds).thenAnswer((_) => Stream.value(const []));
    return households;
  }

  /// Boots the app into [active]'s session, which lands on home.
  Future<AppBootstrapCubit> pumpApp(
    WidgetTester tester,
    ActiveServer active, {
    List<ServerConfig> recoveredServers = const [],
    FeedbackUncaughtErrorReporter? feedbackReporter,
    Future<void> Function()? beforeBoot,
    DependencyContainer? rootContainer,
  }) async {
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        outcomes: [
          BootstrapResult(
            hasServer: true,
            activeServerScope: FakeActiveServerScope(active),
            recoveredServers: recoveredServers,
          ),
        ],
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        feedbackReporter: feedbackReporter,
        rootContainer: rootContainer,
      ),
    );
    await beforeBoot?.call();
    await cubit.initialize();
    await tester.pumpAndSettle();
    return cubit;
  }

  GoRouter routerOf(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
          as GoRouter;

  final rail = find.byKey(NavigationShell.railKey);
  final bar = find.byKey(NavigationShell.barKey);
  final adminEntry = find.byKey(MenuDrawer.entryKey('admin'));
  const allDestinations = ['home', 'collection', 'games', 'events'];

  /// The labels the rail shows its destinations under, in order.
  List<String?> railLabels(WidgetTester tester) => [
    for (final destination in tester.widget<NavigationRail>(rail).destinations)
      (destination.label as Text).data,
  ];

  testWidgets('home shows a rail with every destination the session can '
      'reach', (tester) async {
    await pumpApp(tester, session());

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(rail, findsOneWidget);
    expect(bar, findsNothing);
    for (final id in allDestinations) {
      expect(find.byKey(NavigationShell.destinationKey(id)), findsOneWidget);
    }
    // The labels the menu gave them before they left it, and home's title.
    expect(railLabels(tester), ['Home', 'Collection', 'Games', 'Events']);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 0);
    // The rail carries the menu: home's own app bar shows no button.
    expect(find.byKey(BgePage.menuButtonKey), findsNothing);
    expect(find.byIcon(Icons.menu), findsOneWidget);
  });

  testWidgets('a session without the games remote shows no Games '
      'destination', (tester) async {
    await pumpApp(tester, session(games: false));

    expect(railLabels(tester), ['Home', 'Collection', 'Events']);
    expect(find.byKey(NavigationShell.destinationKey('games')), findsNothing);
  });

  testWidgets('the destinations leave the menu, and the rest of it stays', (
    tester,
  ) async {
    await pumpApp(tester, session());
    await openMenu(tester);

    for (final id in allDestinations) {
      expect(find.byKey(MenuDrawer.entryKey(id)), findsNothing);
    }
    for (final id in ['send_feedback', 'settings', 'sign_out']) {
      expect(find.byKey(MenuDrawer.entryKey(id)), findsOneWidget);
    }
  });

  testWidgets('settings shows no rail, and its menu lists the destinations', (
    tester,
  ) async {
    useSettingsStorage();
    await pumpApp(tester, session());
    await openMenuEntry(tester, 'settings');

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(rail, findsNothing);
    // A screen the menu opens keeps its back arrow (#414), so it shows no
    // menu button.
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsNothing);

    // The menu is the shell's, an edge drag away.
    await tester.dragFrom(const Offset(2, 300), const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
    for (final id in allDestinations) {
      expect(find.byKey(MenuDrawer.entryKey(id)), findsOneWidget);
    }
    expect(
      tester
          .widget<NavigationDrawer>(find.byKey(MenuDrawer.drawerKey))
          .selectedIndex,
      isNull,
      reason: 'settings is none of them',
    );

    // A destination picked there goes to it.
    await tester.tap(find.byKey(MenuDrawer.entryKey('events')));
    await tester.pumpAndSettle();
    expect(find.byType(EventOverviewScreen), findsOneWidget);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 3);
  });

  testWidgets('sign out from the menu on a destination signs out', (
    tester,
  ) async {
    await pumpApp(tester, session());
    await goToDestination(tester, 'collection');
    expect(find.byType(GameCollectionListScreen), findsOneWidget);

    await openMenuEntry(tester, 'sign_out');

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(NavigationShell), findsNothing);
  });

  // #47: the session's sync status, under the drawer's header.
  group("the session's sync status (#47)", () {
    final status = find.descendant(
      of: find.byType(MenuDrawer),
      matching: find.byType(SyncStatusLine),
    );

    testWidgets('the drawer reads All changes synced for a session with an '
        'empty queue', (tester) async {
      await pumpApp(
        tester,
        session(queue: _Queue(), drain: _Drain(), households: noHouseholds()),
      );
      await goToDestination(tester, 'collection');
      await openMenu(tester);

      expect(status, findsOneWidget);
      expect(
        find.descendant(of: status, matching: find.text('All changes synced')),
        findsOneWidget,
      );
    });

    testWidgets('the drawer counts what is waiting', (tester) async {
      await pumpApp(
        tester,
        session(
          queue: _Queue(waiting: 2),
          drain: _Drain(),
          households: noHouseholds(),
        ),
      );
      await openMenu(tester);

      expect(
        find.descendant(of: status, matching: find.text('2 changes waiting')),
        findsOneWidget,
      );
    });

    testWidgets('no status where the stuck changes cannot open', (
      tester,
    ) async {
      // A queue, and no drain to retry through: the home notice's gate. No
      // drawer line, and no scope reading the queue, so no row can say a
      // change couldn't sync with no screen to fix it on, and the strip
      // counts nothing.
      await pumpApp(
        tester,
        session(queue: _Queue(waiting: 2), households: noHouseholds()),
      );
      await openMenu(tester);

      expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
      expect(status, findsNothing);
      expect(find.text('All changes synced'), findsNothing);
      final scope = tester.widget<BgeSyncStatusScope>(
        find.byType(BgeSyncStatusScope),
      );
      expect(scope.waiting, isNull);
      expect(scope.stuck, isNull);
      expect(
        tester
            .widget<OfflineStripHost>(find.byType(OfflineStripHost))
            .waiting!
            .value,
        isNull,
      );
    });

    testWidgets("sign-out clears the strip's count", (tester) async {
      final connectivity = FakeConnectivity();
      addTearDown(connectivity.close);
      await pumpApp(
        tester,
        session(
          queue: _Queue(waiting: 2),
          drain: _Drain(),
          households: noHouseholds(),
        ),
        rootContainer: DependencyContainerImpl()
          ..registerSingleton<ConnectivityService>(connectivity),
      );
      final waiting = tester
          .widget<OfflineStripHost>(find.byType(OfflineStripHost))
          .waiting!;
      expect(waiting.value, 2);
      connectivity.change(ConnectivityState.offline);
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(seconds: 2));
      final detail = find.byKey(BgeOfflineStrip.detailKey);
      expect(tester.widget<Text>(detail).data, '2 changes waiting');

      await openMenuEntry(tester, 'sign_out');

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(waiting.value, isNull);
      expect(
        find.text("You're offline. Changes will sync when you reconnect."),
        findsOneWidget,
      );
      expect(detail, findsNothing);
    });

    testWidgets("a switch in place takes the departing user's count, and "
        "the arriving user's replaces it", (tester) async {
      final starting = Completer<void>();
      final auth = FakeAuthRepository(initialSession: testAuthResponse());
      final queue = _Queue(waiting: 2);
      await pumpApp(
        tester,
        session(
          auth: auth,
          queue: queue,
          drain: _Drain(),
          households: noHouseholds(),
          userSessionScope: _UserSessionScope(
            hold: (userId) => userId == 'u2' ? starting.future : null,
          ),
        ),
      );
      final waiting = tester
          .widget<OfflineStripHost>(find.byType(OfflineStripHost))
          .waiting!;
      expect(waiting.value, 2);

      // What the arriving user's queue holds.
      queue.waiting = 5;
      auth.emitAuthState(
        AuthStateAuthenticated(session: _sessionOf('u2', 'other')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(waiting.value, isNull, reason: 'no session has a count');

      starting.complete();
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(waiting.value, 5);
    });
  });

  testWidgets("the admin entry follows the caller's access", (tester) async {
    final access = FakeCallerAccessRepository(
      FakeCallerAccessRepository.dataGateway(read: AccessExtent.all),
    );
    await pumpApp(
      tester,
      session(access: access, dataGateways: _DataGateways()),
    );
    // Any signed-in screen's menu, not home's alone.
    await goToDestination(tester, 'collection');

    await openMenu(tester);
    expect(adminEntry, findsOneWidget);

    access.current = FakeCallerAccessRepository.dataGateway();
    await tester.pumpAndSettle();
    expect(adminEntry, findsNothing);

    access.current = FakeCallerAccessRepository.dataGateway(
      read: AccessExtent.all,
    );
    await tester.pumpAndSettle();
    expect(adminEntry, findsOneWidget);
  });

  // #432: the departing user's scope is torn down as the switch begins, and
  // the shell's destinations and menu open screens over its services.
  testWidgets("a switch in place shows no chrome until the new user's home", (
    tester,
  ) async {
    final starting = Completer<void>();
    final auth = FakeAuthRepository(initialSession: testAuthResponse());
    await pumpApp(
      tester,
      session(
        auth: auth,
        userSessionScope: _UserSessionScope(
          hold: (userId) => userId == 'u2' ? starting.future : null,
        ),
        access: FakeCallerAccessRepository(
          FakeCallerAccessRepository.dataGateway(read: AccessExtent.all),
        ),
        dataGateways: _DataGateways(),
      ),
    );
    await goToDestination(tester, 'collection');
    expect(rail, findsOneWidget);

    auth.emitAuthState(
      AuthStateAuthenticated(session: _sessionOf('u2', 'other')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(NavigationShell), findsNothing);
    expect(rail, findsNothing);
    expect(bar, findsNothing);
    expect(find.byIcon(Icons.menu), findsNothing);

    starting.complete();
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 0);
  });

  testWidgets('event create from a household shows Events and Back returns', (
    tester,
  ) async {
    useViewSize(tester, const Size(400, 800));
    final households = _MockHouseholdRepository();
    final me = HouseholdMember(
      id: 'm-1',
      userId: 'u1',
      householdId: 'h-1',
      role: HouseholdRole.householdMember,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    when(households.watchHouseholds).thenAnswer(
      (_) => Stream.value([
        Household(
          id: 'h-1',
          name: 'The Smiths',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ]),
    );
    when(() => households.getCurrentUserMember(any()))
        .thenAnswer((_) async => me);
    when(() => households.watchMembers(any()))
        .thenAnswer((_) => Stream.value([me]));
    await pumpApp(
      tester,
      session(
        households: households,
        sender: _Sender(),
        users: _MockUserRemote(),
      ),
    );

    await openMenuEntry(tester, 'households');
    await tester.tap(find.byKey(HouseholdListScreen.rowKey('h-1')));
    await tester.pumpAndSettle();
    expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    expect(bar, findsNothing);

    // Another section's screen, pushed over this one (#414).
    await tester.ensureVisible(find.byKey(HouseholdDetailScreen.newEventKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HouseholdDetailScreen.newEventKey));
    await tester.pumpAndSettle();

    expect(find.byType(CreateEventScreen), findsOneWidget);
    expect(tester.widget<NavigationBar>(bar).selectedIndex, 3);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(CreateEventScreen), findsNothing);
    expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    expect(bar, findsNothing);
  });

  // #428: the notice takes Back through its own handler, which came before
  // the shell's, so the shell's hears it first.
  testWidgets('Back acknowledges the recovery notice before the shell sees '
      'it', (tester) async {
    await pumpApp(
      tester,
      session(),
      recoveredServers: [_server('Game Night')],
    );
    expect(find.byType(AlertDialog), findsOneWidget);
    // A destination's own screen, with nothing beneath it, where the
    // shell's Back would go home.
    routerOf(tester).go(AppRoutes.collection);
    await tester.pumpAndSettle();
    expect(find.byType(GameCollectionListScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(GameCollectionListScreen), findsOneWidget);

    // With the notice gone, Back is the shell's again.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // #106: the crash flow takes every Back while it is up. One that came up
  // before the session did came before the shell too.
  testWidgets('Back reaches a crash prompt that came up before the shell', (
    tester,
  ) async {
    ShellObservability.initialize();
    addTearDown(ShellObservability.reset);
    final reporter = FeedbackUncaughtErrorReporter(
      service: StubFeedbackService(),
    );
    await pumpApp(
      tester,
      session(),
      feedbackReporter: reporter,
      beforeBoot: () async {
        reporter.report(
          UncaughtErrorRecord.capture(
            StateError('bad state'),
            StackTrace.fromString('#0 main (file.dart:1)'),
          ),
        );
        await tester.pump();
      },
    );
    expect(find.byType(CrashReportPrompt), findsOneWidget);
    routerOf(tester).go(AppRoutes.collection);
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(GameCollectionListScreen), findsOneWidget);
    // The prompt's first Back: it arms its dismiss, and shows how.
    expect(
      tester
          .widget<CrashReportPrompt>(find.byType(CrashReportPrompt))
          .showDismissHint,
      isTrue,
    );
  });
}
