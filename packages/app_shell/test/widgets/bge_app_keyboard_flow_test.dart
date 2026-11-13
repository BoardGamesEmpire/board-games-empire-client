import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:di/di.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_onboarding/server_onboarding.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

class _MockEventRepository extends Mock implements EventRepository {}

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

/// A server whose one game is [newest], for home's "Recently added" row.
/// Nothing here opens a game or asks for random ones: the "Something to play"
/// row draws from the collection.
class _OneGameRemote implements GamesRemoteDataSource {
  _OneGameRemote(this.newest);

  final Game newest;

  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
    GameSort sort = GameSort.title,
  }) async => PaginatedResult(
    items: [newest],
    meta: PaginationMeta(
      page: 1,
      limit: limit,
      total: 1,
      totalPages: 1,
      hasMore: false,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Never reached: nothing here submits the server-add form.
class _UnusedWellKnownClient implements WellKnownClient {
  @override
  Future<ServerIdentity> fetchIdentity(String serverUrl) =>
      throw UnimplementedError('the form is never submitted');
}

class _OnlineConnectivity implements ConnectivityService {
  @override
  ConnectivityState get current => ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() =>
      Stream<ConnectivityState>.value(ConnectivityState.online);
}

/// A device that can sign in through a provider, so the provider buttons are
/// enabled and Tab reaches them.
class _ProviderReadyAuthRepository extends FakeAuthRepository {
  @override
  ProviderSignInAvailability get providerSignInAvailability =>
      const ProviderSignInAvailable();
}

OidcStrategy _provider(String id, String name) => OidcStrategy(
  providerId: id,
  displayName: name,
  discoveryUrl: 'https://sso.example.com/$id/.well-known/openid-configuration',
  authorizationEndpoint: '$testAuthBasePath/sign-in/social',
  appSignInEndpoint: '$testAuthBasePath/app-sign-in/start',
  appTokenEndpoint: '$testAuthBasePath/app-sign-in/token',
);

/// [testServerIdentity] with two sign-in providers after its email strategy.
ServerIdentity _identityWithProviders() => testServerIdentity().copyWith(
  strategies: [
    testEmailAndPasswordStrategy(),
    _provider('keycloak', 'Keycloak'),
    _provider('github', 'GitHub'),
  ],
);

/// Signed-in home with every section up: a household, an upcoming event,
/// a game of the user's own and one on the server (#767). The caller sets
/// the window first.
Future<void> _pumpHome(WidgetTester tester) async {
  final repository = _MockHouseholdRepository();
  // A household in the cache, so the list shows rows and the floating
  // Create is the only create control.
  when(repository.watchHouseholds).thenAnswer(
    (_) => Stream<List<Household>>.value([
      Household(
        id: 'hh_1',
        name: 'Sunday Crew',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    ]),
  );
  // One upcoming event, so home builds its upcoming events section.
  // Far enough ahead to stay upcoming, in local time so the card reads the
  // same wherever the suite runs.
  final start = DateTime(2099, 1, 1, 19);
  final eventRepository = _MockEventRepository();
  when(eventRepository.watchAttendingEventListItems).thenAnswer(
    (_) => Stream<List<EventListItem>>.value([
      EventListItem(
        event: Event(
          id: 'e1',
          title: 'Game night',
          createdById: 'user-host',
          type: EventType.casualGathering,
          reach: Reach.friends,
          status: EventStatus.planning,
          schedulingMode: EventSchedulingMode.fixed,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        occurrences: [
          EventOccurrence(
            id: 'o1',
            eventId: 'e1',
            startDate: start,
            status: OccurrenceStatus.confirmed,
            sortOrder: 0,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ],
      ),
    ]),
  );
  // One game of the user's own, so home builds its stats card, and its
  // "Something to play" row draws that game. Another on the server, so the
  // "Recently added" row has one too (#767).
  final collection = _MockGameCollectionRepository();
  when(collection.watchCollectionListItems).thenAnswer(
    (_) => Stream<List<GameCollectionListItem>>.value([
      GameCollectionListItem(
        entry: GameCollection(
          id: 'entry-azul',
          userId: 'u1',
          platformGameId: 'pg-azul',
          medium: GameMedium.physical,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        gameId: 'azul',
        title: 'Azul',
        platformName: 'Board game',
      ),
    ]),
  );
  final cubit = _MockAppBootstrapCubit();
  when(() => cubit.activeServerScope).thenReturn(
    FakeActiveServerScope(
      buildActiveServer(
        FakeAuthRepository(initialSession: testAuthResponse()),
        householdRepository: repository,
        eventRepository: eventRepository,
        gameCollectionRepository: collection,
        gamesRemoteDataSource: _OneGameRemote(
          Game(
            id: 'cascadia',
            title: 'Cascadia',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ),
        // The create route's guard: without a sender, the list offers no
        // create (#121).
        syncOperationSender: _MockSyncOperationSender(),
      ),
    ),
  );
  whenListen(
    cubit,
    const Stream<AppBootstrapState>.empty(),
    initialState: const AppBootstrapReady(),
  );

  await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
  await tester.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget);

  // Every section is up, so the walk crosses all four (#767).
  expect(find.byKey(StatsCard.ownedKey), findsOneWidget);
  expect(find.byKey(NewestGamesSection.coverKey('cascadia')), findsOneWidget);
  expect(find.byKey(SomethingToPlaySection.coverKey('azul')), findsOneWidget);
}

/// Keyboard flows through the real app root (#50): Tab follows the order a
/// screen reads in, Shift+Tab walks it back, nothing traps focus, and focus
/// goes back to the control that opened a route once the route closes.
///
/// The harnesses are the ones `server_add_route_test.dart` (server-add),
/// `bge_app_auth_wiring_test.dart` (sign-in) and
/// `bge_app_household_menu_test.dart` (the signed-in home) build, with each of
/// home's sections' sources registered as `bge_app_home_sections_test.dart`
/// registers them.
void main() {
  late SemanticsHandle semantics;

  setUp(() {
    // `tabOrder` names each stop from the semantics tree.
    semantics = SemanticsBinding.instance.ensureSemantics();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  tearDown(() => semantics.dispose());

  testWidgets('server add: Tab follows reading order with no trap', (
    tester,
  ) async {
    // The composition native's root module registers for /server-add.
    final container = DependencyContainerImpl()
      ..registerLazySingleton<WellKnownClient>(_UnusedWellKnownClient.new)
      ..registerLazySingleton<VersionNegotiator>(VersionNegotiatorImpl.new)
      ..registerLazySingleton<ConnectivityService>(_OnlineConnectivity.new)
      ..registerSingleton<BuildInfo>(BuildInfo.unknown);
    container.registerLazySingleton<ServerOnboardingDeps>(
      () => ServerOnboardingDeps.from(container),
    );
    addTearDown(container.dispose);
    final cubit = _MockAppBootstrapCubit();
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapNeedsServer(),
    );
    when(() => cubit.orchestrator).thenReturn(_MockServerOrchestrator());
    when(() => cubit.activeServerScope).thenReturn(null);

    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, rootContainer: container),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ServerAddScreen), findsOneWidget);

    // Title and intro are text, then the address, the nickname and the
    // submit, top to bottom.
    await expectTraversable(
      tester,
      expectedOrder: ['Server address', 'Nickname (optional)', 'Connect'],
    );
  });

  testWidgets('sign in: Tab follows reading order with no trap', (
    tester,
  ) async {
    final repo = _ProviderReadyAuthRepository(); // no session
    final server = buildActiveServer(repo);
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        activeServerScope: FakeActiveServerScope(
          ActiveServer(
            serverId: server.serverId,
            displayName: server.displayName,
            identity: _identityWithProviders(),
            container: server.container,
          ),
        ),
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(AuthScreen), findsOneWidget);

    // The email form top to bottom, the password's show toggle at the end of
    // its field, the switch to register under the submit, then the provider
    // buttons below the "or" divider. The email field reads its hint with
    // its label.
    await expectTraversable(
      tester,
      expectedOrder: [
        'Email\nEnter your email address',
        'Password',
        'Show password',
        'Sign In',
        "Don't have an account? Register",
        'Continue with Keycloak',
        'Continue with GitHub',
      ],
    );
  });

  testWidgets('home → create household: Tab follows reading order with no '
      'trap on each, Escape closes the drawer back to its opener, and back '
      'returns focus to the opener', (tester) async {
    // A phone's window: home carries the menu button in its app bar, and the
    // destinations go on the bar along the bottom (#414).
    useViewSize(tester, const Size(400, 800));
    await _pumpHome(tester);

    // The menu button, then the sections top to bottom. Upcoming events: its
    // See all link in the heading row, then the card, which reads its title
    // and when. The stats card has no stop: its heading and count are text,
    // and its households link shows only to someone in no household. Each row
    // of games: the link or button in its heading row, then its cover. One
    // cover fits, so neither row shows its previous and next buttons. Then
    // the bar's destinations (#414): Collection, Games and Events are there
    // because the collection repository, the games remote and the event
    // repository are registered. Material reads each with "Tab n of m".
    await expectTraversable(
      tester,
      expectedOrder: [
        'Open navigation menu',
        'See all your events',
        'Game night\nThu, Jan 1, 2099 · 7:00 PM',
        'See all recently added games',
        'Cascadia',
        'Reshuffle',
        'Azul',
        'Home\nTab 1 of 4',
        'Collection\nTab 2 of 4',
        'Games\nTab 3 of 4',
        'Events\nTab 4 of 4',
      ],
    );

    // The drawer, from the menu button: its entries, then its action under
    // the divider. The bar carries the destinations, so the drawer lists
    // none (#414), and each entry is a button, read without "Tab n of m"
    // (#763).
    final menu = find.byIcon(Icons.menu);
    final menuNode = Focus.of(tester.element(menu));
    await activateByKeyboard(tester, menu);
    expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
    await expectTraversable(
      tester,
      expectedOrder: ['Households', 'Send feedback', 'Settings', 'Sign Out'],
    );

    // Escape closes it, and focus goes back to the menu button.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(MenuDrawer.drawerKey), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(menuNode));

    // Open again, then the households entry.
    await activateByKeyboard(tester, menu);
    expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
    await activateByKeyboard(
      tester,
      find.descendant(
        of: find.byKey(MenuDrawer.entryKey('households')),
        matching: find.text('Households'),
      ),
    );
    expect(find.byType(HouseholdListScreen), findsOneWidget);

    // The back control, the row, then the floating Create.
    await expectTraversable(
      tester,
      expectedOrder: ['Back', 'Sunday Crew', 'Create household'],
    );

    // A page route takes no Escape: only a route the barrier dismisses does.
    // Its back button is how a keyboard leaves it.
    await expectFocusReturnsAfterDialog(
      tester,
      opener: find.descendant(
        of: find.byKey(HouseholdListScreen.createFabKey),
        matching: find.text('Create household'),
      ),
      dismiss: () async {
        expect(find.byType(CreateHouseholdScreen), findsOneWidget);
        // The back button, then the form top to bottom.
        await expectTraversable(
          tester,
          expectedOrder: [
            'Back',
            'Household name',
            'Description (optional)',
            'Create household',
          ],
        );
        await activateByKeyboard(
          tester,
          find.descendant(
            of: find.byType(BackButton),
            matching: find.byType(Icon),
          ),
        );
      },
    );
    expect(find.byType(CreateHouseholdScreen), findsNothing);
    expect(find.byType(HouseholdListScreen), findsOneWidget);
  });

  testWidgets('home at a medium window: Tab meets the page, then the rail in '
      'the order it is drawn, with no trap', (tester) async {
    // The default 800x600 window: a rail at the start, its menu button at
    // the top, and the page without one (#414).
    await _pumpHome(tester);
    expect(find.byKey(NavigationShell.railKey), findsOneWidget);
    expect(find.byKey(NavigationShell.barKey), findsNothing);

    // The page's content first, top to bottom, then the rail as it is
    // drawn: the menu button, then Home to Events. At a phone's width the
    // bar comes after the content the same way, but the menu button there
    // is the page's own, in its app bar, and leads (see the compact walk
    // above). The rail is a traversal group of its own, so the walk takes
    // its stops together and not scattered among the page's. Material reads
    // each destination with "Tab n of m".
    await expectTraversable(
      tester,
      expectedOrder: [
        'See all your events',
        'Game night\nThu, Jan 1, 2099 · 7:00 PM',
        'See all recently added games',
        'Cascadia',
        'Reshuffle',
        'Azul',
        'Open navigation menu',
        'Home\nTab 1 of 4',
        'Collection\nTab 2 of 4',
        'Games\nTab 3 of 4',
        'Events\nTab 4 of 4',
      ],
    );

    // The drawer from the rail's menu button lists entries only.
    await activateByKeyboard(tester, find.byIcon(Icons.menu));
    expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
    await expectTraversable(
      tester,
      expectedOrder: ['Households', 'Send feedback', 'Settings', 'Sign Out'],
    );
  });
}
