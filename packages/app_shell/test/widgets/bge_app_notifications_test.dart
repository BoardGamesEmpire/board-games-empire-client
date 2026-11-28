import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:events/events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_collection/game_collection.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/notifications.dart';
import 'package:ui/ui.dart' show BgePage;

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';
import '../support/navigation.dart';
import '../support/no_later_recoveries.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    with NoLaterRecoveries
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

/// The server's notifications for whoever is signed in: [countOf] answers
/// the unread count, and every page holds [items]. Mark all read marks the
/// server's count down to nothing.
class _Notifications implements NotificationRemoteDataSource {
  _Notifications({int unread = 0, this.items = const []})
    : countOf = (() => unread);

  int Function() countOf;
  final List<UserNotification> items;

  /// How many times the unread count was read.
  int countReads = 0;

  /// The limit of each page read, in order.
  final List<int> pageReads = [];

  /// The ids of each mark read, in order.
  final List<List<String>> marked = [];

  @override
  Future<int> fetchUnreadCount() async {
    countReads++;
    return countOf();
  }

  @override
  Future<NotificationPage> fetchPage({
    String? cursor,
    int limit = NotificationRemoteDataSource.defaultPageSize,
  }) async {
    pageReads.add(limit);
    return NotificationPage(items: items.take(limit).toList());
  }

  @override
  Future<void> markRead(List<String> ids) async => marked.add(ids);

  @override
  Future<void> markAllRead() async => countOf = () => 0;

  @override
  Future<List<UnreadNotification>> fetchUnread() => throw UnimplementedError();
}

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

/// Answers the owner's profile and nothing else.
class _Profile implements UserProfileRemoteDataSource {
  @override
  Future<UserProfile> fetchOwn() async => const UserProfile(
    userId: 'u-me',
    username: 'me',
    willingToTeach: false,
    openToNewPlayers: false,
    hostingCapability: false,
    reach: Reach.friends,
    isSearchable: true,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers with whichever server the test made active last.
class _SwitchableScope implements ActiveServerScope {
  _SwitchableScope(this._read);

  final ActiveServer Function() _read;

  @override
  ActiveServer? get active => _read();

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(_read());
}

/// A user scope that holds whoever the shell last activated, and starts a
/// new lease for each, as the real one registers one per session.
class _LeasingUserSessionScope implements UserSessionScope {
  FakeSessionLease lease = FakeSessionLease();

  @override
  String? activeUserId;

  @override
  Future<void> activate(String userId) async {
    lease = FakeSessionLease();
    activeUserId = userId;
  }

  @override
  Future<void> deactivate() async {
    lease.isLive = false;
    activeUserId = null;
  }
}

const _id = 'hh_1';

UserNotification _accepted(String id, {String householdId = _id}) =>
    UserNotification(
      id: id,
      type: 'HouseholdInviteAccepted',
      payload: {
        'householdId': householdId,
        'householdName': 'Sunday Crew',
        'memberName': 'Robin',
      },
      read: false,
      createdAt: DateTime.utc(2026, 11, 27),
    );

UserNotification _declined(String id) => UserNotification(
  id: id,
  type: 'HouseholdInviteDeclined',
  payload: const {
    'householdId': _id,
    'householdName': 'Sunday Crew',
    'inviteeName': 'Sam',
  },
  read: false,
  createdAt: DateTime.utc(2026, 11, 27),
);

HouseholdMember _viewer(HouseholdRole role) => HouseholdMember(
  id: 'm-me',
  userId: 'u-me',
  householdId: _id,
  role: role,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

AuthResponse _sessionOf(String id, String username) => testAuthResponse()
    .copyWith(token: null)
    .copyWith
    .user(id: id, username: username, email: '$id@example.com');

final Finder _bell = find.byKey(NotificationsBell.buttonKey);

/// The bell's badge reading [text].
Finder _badge(String text) =>
    find.descendant(of: _bell, matching: find.text(text));

/// The bell in the header of the screen [screen], on the page showing.
Finder _bellIn(Type screen) => find.descendant(
  of: find.descendant(
    of: find.byType(screen),
    matching: find.byType(AppBar),
  ),
  matching: _bell,
);

/// The #475 wiring that lives inside [BgeApp]: the Notifications page's
/// route and its menu entry, the session's unread count above the shell, the
/// bell in the four top-level headers and its preview, and where a
/// notification opens. The notifications package's own tests cover the page,
/// the preview and the bell; the router's cover the route table.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  /// The active server, read whenever the shell asks for it.
  late ActiveServer active;

  /// The session's lease, read whenever the shell asks for it.
  late SessionLease lease;

  /// A household cache holding [households], where the viewer is [role] in
  /// each.
  HouseholdRepository householdsOf({
    List<Household> households = const [],
    HouseholdRole role = HouseholdRole.householdOwner,
  }) {
    final repository = _MockHouseholdRepository();
    when(repository.watchHouseholds)
        .thenAnswer((_) => Stream.value(households));
    when(
      () => repository.watchMembers(any()),
    ).thenAnswer((_) => Stream.value(const []));
    when(
      () => repository.getCurrentUserMember(any()),
    ).thenAnswer((_) async => _viewer(role));
    return repository;
  }

  /// Boots the app at home, signed in to a server with [notifications] and
  /// [households], a collection, the games catalog and events, so all four
  /// top-level screens are there. With [profile], the menu offers the
  /// profile too. With [web], the browser owns Back, as in the browser app.
  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    _Notifications? notifications,
    HouseholdRepository? households,
    bool withHouseholds = true,
    bool profile = false,
    bool web = false,
  }) async {
    lease = FakeSessionLease();
    active = buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
      householdRepository: withHouseholds
          ? (households ?? householdsOf())
          : null,
      notificationRemoteDataSource: notifications,
      userProfileRemoteDataSource: profile ? _Profile() : null,
      gameCollectionRepository: _Collection(),
      gamesRemoteDataSource: _Games(),
      eventRepository: _Events(),
    );
    active.container.registerFactory<SessionLease>(() => lease);
    addTearDown(active.container.dispose);
    when(
      () => cubit.activeServerScope,
    ).thenReturn(_SwitchableScope(() => active));
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, browserOwnsBack: web),
    );
    await tester.pumpAndSettle();
    return tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
        as GoRouter;
  }

  group('the Notifications page (#475)', () {
    testWidgets('the drawer lists Notifications after Profile and opens '
        '/notifications', (tester) async {
      final router = await pumpApp(
        tester,
        notifications: _Notifications(),
        profile: true,
      );
      await openMenu(tester);

      final ids = [
        for (final entry
            in tester.widget<MenuDrawer>(find.byType(MenuDrawer)).entries)
          entry.id,
      ];
      expect(ids, contains('profile'));
      expect(ids.indexOf('notifications'), ids.indexOf('profile') + 1);
      final entry = find.byKey(MenuDrawer.entryKey('notifications'));
      expect(
        find.descendant(of: entry, matching: find.text('Notifications')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: entry,
          matching: find.byIcon(Icons.notifications_outlined),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Inbox'), findsNothing);

      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.byType(NotificationsScreen), findsOneWidget);
      expect(router.state.uri.path, AppRoutes.notifications);
    });

    testWidgets('a server without the notifications client offers no entry '
        'and no bell', (tester) async {
      await pumpApp(tester);
      expect(_bell, findsNothing);

      await openMenu(tester);
      expect(find.byKey(MenuDrawer.entryKey('notifications')), findsNothing);
    });

    testWidgets('no user session, no entry and no bell', (tester) async {
      await pumpApp(
        tester,
        notifications: _Notifications(),
        withHouseholds: false,
      );
      expect(_bell, findsNothing);

      await openMenu(tester);
      expect(find.byKey(MenuDrawer.entryKey('notifications')), findsNothing);
    });

    testWidgets('/notifications without a NotificationRemoteDataSource shows '
        'NotYetAvailableScreen', (tester) async {
      final router = await pumpApp(tester);

      router.go(AppRoutes.notifications);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(NotificationsScreen), findsNothing);
    });

    testWidgets("the page reads the active server's notifications, and what "
        "it marks read reaches the bell's count", (tester) async {
      final notifications = _Notifications(
        unread: 2,
        items: [_accepted('n1'), _accepted('n2')],
      );
      await pumpApp(tester, notifications: notifications);
      expect(_badge('2'), findsOneWidget);

      await openMenuEntry(tester, 'notifications');
      expect(find.byKey(NotificationsScreen.rowKey('n1')), findsOneWidget);
      expect(
        notifications.pageReads,
        [NotificationRemoteDataSource.defaultPageSize],
      );

      await tester.tap(find.byKey(NotificationsScreen.markAllKey));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(_badge('2'), findsNothing);
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: _bell, matching: find.byType(Icon)),
            )
            .semanticLabel,
        'Notifications',
      );
    });
  });

  group('the bell (#475)', () {
    testWidgets('the bell sits in the Home, Collection, Games and Events '
        'headers and not on a pushed screen', (tester) async {
      final router = await pumpApp(
        tester,
        notifications: _Notifications(unread: 3),
      );

      expect(_bellIn(HomeScreen), findsOneWidget);
      expect(_badge('3'), findsOneWidget);
      for (final (id, screen) in [
        ('collection', GameCollectionListScreen),
        ('games', GameBrowseScreen),
        ('events', EventOverviewScreen),
      ]) {
        await goToDestination(tester, id);
        expect(find.byType(screen), findsOneWidget, reason: id);
        expect(_bellIn(screen), findsOneWidget, reason: id);
        expect(_badge('3'), findsOneWidget, reason: id);
      }

      // Games pushed over Collection, as its empty state's browse does: a
      // page with a way back, not the destination's own screen.
      await goToDestination(tester, 'collection');
      unawaited(router.push<void>(AppRoutes.games));
      await tester.pumpAndSettle();
      expect(find.byType(GameBrowseScreen), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(_bell, findsNothing);

      // And Collection pushed over home.
      router.go(AppRoutes.home);
      await tester.pumpAndSettle();
      unawaited(router.push<void>(AppRoutes.collection));
      await tester.pumpAndSettle();
      expect(find.byType(GameCollectionListScreen), findsOneWidget);
      expect(_bell, findsNothing);

      // Back on the screen beneath, the bell is there again.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_bellIn(HomeScreen), findsOneWidget);
    });

    // Where the browser owns Back, a section's top shows the menu however it
    // was reached (#611), and so the bell with it: the stack is the browser
    // history's, not a way back the page offers.
    testWidgets('where the browser owns Back, a top-level screen pushed over '
        'another keeps its menu button and the bell', (tester) async {
      useViewSize(tester, const Size(360, 740));
      final router = await pumpApp(
        tester,
        notifications: _Notifications(unread: 3),
        web: true,
      );
      await goToDestination(tester, 'collection');

      unawaited(router.push<void>(AppRoutes.games));
      await tester.pumpAndSettle();

      expect(find.byType(GameBrowseScreen), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(
        find.descendant(
          of: find.byType(GameBrowseScreen),
          matching: find.byKey(BgePage.menuButtonKey),
        ),
        findsOneWidget,
      );
      expect(_bellIn(GameBrowseScreen), findsOneWidget);
      expect(_badge('3'), findsOneWidget);
    });

    testWidgets('the bell is in the header at a compact width too, and never '
        'on the bar or the rail', (tester) async {
      useViewSize(tester, const Size(360, 740));
      await pumpApp(tester, notifications: _Notifications(unread: 3));

      expect(find.byKey(NavigationShell.barKey), findsOneWidget);
      expect(_bellIn(HomeScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(NavigationShell.barKey),
          matching: _bell,
        ),
        findsNothing,
      );

      useViewSize(tester, const Size(1200, 800));
      await tester.pumpAndSettle();
      expect(find.byKey(NavigationShell.railKey), findsOneWidget);
      expect(_bellIn(HomeScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(NavigationShell.railKey),
          matching: _bell,
        ),
        findsNothing,
      );
    });

    testWidgets('tapping the bell opens the preview; See all lands on '
        '/notifications and Back returns to the screen beneath', (
      tester,
    ) async {
      final notifications = _Notifications(
        unread: 1,
        items: [_accepted('n1')],
      );
      final router = await pumpApp(tester, notifications: notifications);
      await goToDestination(tester, 'games');
      final countReads = notifications.countReads;

      await tester.tap(_bell);
      await tester.pumpAndSettle();
      expect(find.byKey(NotificationsPreview.contentKey), findsOneWidget);
      expect(
        find.byKey(NotificationsPreview.rowKey('n1')),
        findsOneWidget,
      );
      expect(notifications.pageReads, [NotificationsPreview.pageSize]);
      // The preview reads the count again as it opens.
      expect(notifications.countReads, greaterThan(countReads));

      await tester.tap(find.byKey(NotificationsPreview.seeAllKey));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsScreen), findsOneWidget);
      expect(router.state.uri.path, AppRoutes.notifications);
      expect(
        find.byKey(NotificationsPreview.contentKey, skipOffstage: false),
        findsNothing,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(GameBrowseScreen), findsOneWidget);
      expect(router.state.uri.path, AppRoutes.games);
      expect(find.byKey(NotificationsPreview.contentKey), findsNothing);
    });

    testWidgets('a row in the preview opens what it is about, and Back '
        'returns to the screen beneath with no preview', (tester) async {
      final router = await pumpApp(
        tester,
        notifications: _Notifications(unread: 1, items: [_accepted('n1')]),
        households: householdsOf(
          households: [
            Household(
              id: _id,
              name: 'Sunday Crew',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          ],
        ),
      );

      await tester.tap(_bell);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NotificationsPreview.rowKey('n1')));
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(router.state.uri.path, AppRoutes.householdDetailOf(_id));
      expect(
        find.byKey(NotificationsPreview.contentKey, skipOffstage: false),
        findsNothing,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byKey(NotificationsPreview.contentKey), findsNothing);
    });
  });

  group('opening a notification (#475)', () {
    testWidgets('a HouseholdTarget for a household no longer on the device '
        'opens the not-found page', (tester) async {
      final router = await pumpApp(
        tester,
        notifications: _Notifications(
          unread: 1,
          items: [_accepted('n1', householdId: 'hh_gone')],
        ),
      );
      await openMenuEntry(tester, 'notifications');

      await tester.tap(find.byKey(NotificationsScreen.rowKey('n1')));
      await tester.pumpAndSettle();

      expect(router.state.uri.path, AppRoutes.householdDetailOf('hh_gone'));
      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsScreen), findsOneWidget);
    });

    testWidgets("a declined invite opens the household's invites on Declined "
        'for its owner', (tester) async {
      final router = await pumpApp(
        tester,
        notifications: _Notifications(items: [_declined('n1')]),
      );
      await openMenuEntry(tester, 'notifications');

      await tester.tap(find.byKey(NotificationsScreen.rowKey('n1')));
      await tester.pumpAndSettle();

      expect(
        router.state.uri.toString(),
        AppRoutes.householdInvitesOf(_id, declined: true),
      );
      // This harness has no invite client, so the screen is the fallback;
      // bge_app_household_invites_test opens the list on Declined.
    });

    testWidgets('a declined invite opens the sent invites on Declined for a '
        'member', (tester) async {
      final router = await pumpApp(
        tester,
        notifications: _Notifications(items: [_declined('n1')]),
        households: householdsOf(role: HouseholdRole.householdMember),
      );
      await openMenuEntry(tester, 'notifications');

      await tester.tap(find.byKey(NotificationsScreen.rowKey('n1')));
      await tester.pumpAndSettle();

      expect(
        router.state.uri.toString(),
        AppRoutes.invitesSentOf(declined: true),
      );
    });

    testWidgets("the page's rows open again once what one opened has gone", (
      tester,
    ) async {
      final router = await pumpApp(
        tester,
        notifications: _Notifications(
          items: [
            _accepted('n1', householdId: 'hh_a'),
            _accepted('n2', householdId: 'hh_b'),
          ],
        ),
      );
      await openMenuEntry(tester, 'notifications');

      await tester.tap(find.byKey(NotificationsScreen.rowKey('n1')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRoutes.householdDetailOf('hh_a'));
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(NotificationsScreen.rowKey('n2')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRoutes.householdDetailOf('hh_b'));
    });

    testWidgets('a notification opened as its session ends opens nothing for '
        'the next', (tester) async {
      final households = householdsOf();
      final read = Completer<HouseholdMember?>();
      when(
        () => households.getCurrentUserMember(_id),
      ).thenAnswer((_) => read.future);
      final router = await pumpApp(
        tester,
        notifications: _Notifications(items: [_declined('n1')]),
        households: households,
      );
      await openMenuEntry(tester, 'notifications');

      await tester.tap(find.byKey(NotificationsScreen.rowKey('n1')));
      await tester.pump();
      (lease as FakeSessionLease).isLive = false;
      read.complete(_viewer(HouseholdRole.householdOwner));
      await tester.pumpAndSettle();

      expect(router.state.uri.path, AppRoutes.notifications);
    });
  });

  group('sessions (#475)', () {
    testWidgets('a new session on the same server gets a fresh count', (
      tester,
    ) async {
      final notifications = _Notifications(unread: 3);
      final router = await pumpApp(tester, notifications: notifications);
      expect(_badge('3'), findsOneWidget);
      final countReads = notifications.countReads;

      // Another session on the same server container: the remote is the
      // same object, so only the lease tells the sessions apart. Nothing on
      // home reads the count again by itself.
      lease = FakeSessionLease();
      notifications.countOf = () => 5;
      unawaited(router.push(AppRoutes.settings));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(notifications.countReads, countReads + 1);
      expect(_badge('5'), findsOneWidget);
      expect(_badge('3'), findsNothing);
    });

    testWidgets('a new session on the same server gets a fresh Notifications '
        'page', (tester) async {
      final notifications = _Notifications(
        unread: 1,
        items: [_accepted('n1')],
      );
      final router = await pumpApp(tester, notifications: notifications);
      await openMenuEntry(tester, 'notifications');
      Element page() => tester.element(find.byType(NotificationsScreen));
      final first = page();
      final pageReads = notifications.pageReads.length;

      lease = FakeSessionLease();
      unawaited(router.push(AppRoutes.settings));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<NotificationsScreen>(find.byType(NotificationsScreen))
            .key,
        ValueKey((active, lease)),
      );
      expect(page(), isNot(same(first)));
      expect(first.mounted, isFalse);
      // A new list, read for the new session.
      expect(notifications.pageReads, hasLength(pageReads + 1));
    });

    testWidgets("switching to another user's session shows that session's "
        'count, not the last one', (tester) async {
      final repo = FakeAuthRepository(initialSession: testAuthResponse());
      final scope = _LeasingUserSessionScope();
      final notifications = _Notifications()
        ..countOf = () => scope.activeUserId == 'u2' ? 7 : 3;
      final server = buildActiveServer(
        repo,
        householdRepository: householdsOf(),
        notificationRemoteDataSource: notifications,
        userSessionScope: scope,
      );
      server.container.registerFactory<SessionLease>(() => scope.lease);
      final bootstrap = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(
          activeServerScope: FakeActiveServerScope(server),
        ),
        hydratedStorageInitializer: (_) async {},
      );
      addTearDown(bootstrap.close);
      await tester.pumpWidget(BgeApp(bootstrapCubit: bootstrap));
      await bootstrap.initialize();
      await tester.pumpAndSettle();
      expect(scope.activeUserId, 'u1');
      expect(_badge('3'), findsOneWidget);

      repo.emitAuthState(
        AuthStateAuthenticated(session: _sessionOf('u2', 'other')),
      );
      await tester.pumpAndSettle();

      expect(scope.activeUserId, 'u2');
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(_badge('7'), findsOneWidget);
      expect(_badge('3'), findsNothing);
      // The shell the count's host brings back still says whose account
      // the tab now shows.
      expect(
        find.text(
          'other signed in from another tab, so this tab switched to their '
          'account.',
        ),
        findsOneWidget,
      );
    });
  });
}
