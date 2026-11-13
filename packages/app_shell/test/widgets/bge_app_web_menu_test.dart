import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:events/events.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart' show FeedbackService;
import 'package:ui/ui.dart' show BgePage;

import '../support/active_server_fakes.dart';
import '../support/fake_browser_history.dart';
import '../support/fake_platform_bootstrap.dart';
import '../support/navigation.dart';
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

/// What a create sends through. Nothing here sends.
class _Sender implements SyncOperationSender {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockUserRemote extends Mock implements UserRemoteDataSource {}

class _MockStorage extends Mock implements Storage {}

/// Settings builds once the app-level settings controllers exist, and those
/// need hydrated storage.
void _useSettingsStorage() {
  final storage = _MockStorage();
  when(() => storage.read(any())).thenReturn(null);
  when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
  HydratedBloc.storage = storage;
  addTearDown(() => HydratedBloc.storage = null);
}

/// One household, The Smiths, with the user a plain member of it.
HouseholdRepository _households() {
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
  when(
    () => households.getCurrentUserMember(any()),
  ).thenAnswer((_) async => me);
  when(
    () => households.watchMembers(any()),
  ).thenAnswer((_) => Stream.value([me]));
  return households;
}

/// On the web the browser's own Back is the way back (#611), so no
/// signed-in screen shows an in-app back arrow: the top of every section,
/// each destination and every screen the menu opens, shows the menu in its
/// place, and a page under one shows nothing. A cancel in a flow is an
/// action, not navigation, and stays.
///
/// The rule itself is pinned at its seam in the ui package's
/// `bge_navigation_menu_test.dart`, and which pages are a section's top in
/// `app_router_test.dart`. What only this file can check is the app handing
/// the rule down, and the walk a user takes with it.
void main() {
  /// A signed-in session on a server offering a collection, the games
  /// catalog, events and one household.
  ActiveServer session() => buildActiveServer(
    FakeAuthRepository(initialSession: testAuthResponse()),
    gameCollectionRepository: _Collection(),
    gamesRemoteDataSource: _Games(),
    eventRepository: _Events(),
    householdRepository: _households(),
    syncOperationSender: _Sender(),
    userRemoteDataSource: _MockUserRemote(),
  );

  /// Boots the app into a session at 400×800, a phone's compact window,
  /// which lands on home.
  Future<void> pumpApp(
    WidgetTester tester, {
    required bool browserOwnsBack,
    FeedbackService? feedback,
  }) async {
    useViewSize(tester, const Size(400, 800));
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        outcomes: [
          BootstrapResult(
            hasServer: true,
            activeServerScope: FakeActiveServerScope(session()),
          ),
        ],
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);
    final root = DependencyContainerImpl();
    if (feedback != null) root.registerSingleton<FeedbackService>(feedback);
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        rootContainer: feedback == null ? null : root,
        browserOwnsBack: browserOwnsBack,
      ),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
  }

  final bar = find.byKey(NavigationShell.barKey);
  final menuButton = find.byKey(BgePage.menuButtonKey);
  const destinations = {
    'home': HomeScreen,
    'collection': GameCollectionListScreen,
    'games': GameBrowseScreen,
    'events': EventOverviewScreen,
  };

  /// The app bar of the page [screen] builds.
  AppBar appBarOf(WidgetTester tester, Type screen) => tester.widget<AppBar>(
    find.descendant(of: find.byType(screen), matching: find.byType(AppBar)),
  );

  /// Opens the review step of the feedback flow with a valid bug report.
  Future<void> composeValidBug(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(FeedbackComposeForm.severityFieldKey),
    );
    await tester.tap(find.byKey(FeedbackComposeForm.severityFieldKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      'it broke',
    );
    await tester.ensureVisible(
      find.byKey(FeedbackComposeSubmitButton.buttonKey),
    );
    await tester.tap(find.byKey(FeedbackComposeSubmitButton.buttonKey));
    await tester.pumpAndSettle();
  }

  group('where the browser owns Back (#611)', () {
    testWidgets('settings opened from the menu shows the menu, and it reaches '
        'every destination', (tester) async {
      _useSettingsStorage();
      await pumpApp(tester, browserOwnsBack: true);

      for (final (index, id) in destinations.keys.indexed) {
        await openMenuEntry(tester, 'settings');
        expect(find.byType(SettingsScreen), findsOneWidget);
        // Pushed over the page it was opened from, and a section's top.
        expect(menuButton, findsOneWidget);
        expect(find.byType(BackButton), findsNothing);
        expect(bar, findsNothing);

        await tester.tap(menuButton);
        await tester.pumpAndSettle();
        // With no bar here, the menu lists every destination, and the rest
        // of the sections.
        for (final entry in [
          ...destinations.keys,
          'households',
          'send_feedback',
          'settings',
        ]) {
          expect(find.byKey(MenuDrawer.entryKey(entry)), findsOneWidget);
        }
        await tester.tap(find.byKey(MenuDrawer.entryKey(id)));
        await tester.pumpAndSettle();

        expect(find.byType(destinations[id]!), findsOneWidget, reason: id);
        expect(tester.widget<NavigationBar>(bar).selectedIndex, index);
        expect(menuButton, findsOneWidget, reason: id);
        expect(find.byType(BackButton), findsNothing, reason: id);
      }
    });

    testWidgets('household detail shows no back arrow', (tester) async {
      final history = FakeBrowserHistory.install(tester);
      await pumpApp(tester, browserOwnsBack: true);

      await openMenuEntry(tester, 'households');
      expect(find.byType(HouseholdListScreen), findsOneWidget);
      expect(menuButton, findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      await tester.tap(find.byKey(HouseholdListScreen.rowKey('h-1')));
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      final appBar = appBarOf(tester, HouseholdDetailScreen);
      expect(appBar.leading, isNull);
      expect(appBar.automaticallyImplyLeading, isFalse);
      expect(find.byType(BackButton), findsNothing);
      expect(menuButton, findsNothing);

      // The browser's Back is the way back.
      await history.back();
      expect(find.byType(HouseholdDetailScreen), findsNothing);
      expect(find.byType(HouseholdListScreen), findsOneWidget);
      expect(menuButton, findsOneWidget);
    });

    testWidgets('browser Back with the menu open closes it over the page '
        'Back went to, and focus goes to its menu button', (tester) async {
      _useSettingsStorage();
      final history = FakeBrowserHistory.install(tester);
      await pumpApp(tester, browserOwnsBack: true);
      await openMenuEntry(tester, 'settings');
      await tester.tap(menuButton);
      await tester.pumpAndSettle();
      expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);

      await history.back();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byKey(MenuDrawer.drawerKey), findsNothing);
      expect(
        find.ancestor(
          of: find.byElementPredicate(
            (element) => element == FocusManager.instance.primaryFocus?.context,
          ),
          matching: menuButton,
        ),
        findsOneWidget,
      );
    });

    // Back restores home and settings at once, home beneath settings and
    // never laid out. On a pointer platform, which has the selection
    // region, home's text broke the region's sort (see BgeSelectionPage).
    // macOS is a desktop browser on a Mac.
    testWidgets('browser Back from a section picked on settings goes back to '
        'settings', (tester) async {
      _useSettingsStorage();
      final history = FakeBrowserHistory.install(tester);
      await pumpApp(tester, browserOwnsBack: true);
      await openMenuEntry(tester, 'settings');
      await tester.tap(menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MenuDrawer.entryKey('collection')));
      await tester.pumpAndSettle();
      expect(find.byType(GameCollectionListScreen), findsOneWidget);

      await history.back();

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(menuButton, findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    // A cancel in a flow is an action, not navigation (#611).
    testWidgets('feedback review keeps its cancel', (tester) async {
      await pumpApp(
        tester,
        browserOwnsBack: true,
        feedback: StubFeedbackService(),
      );

      await openMenuEntry(tester, 'send_feedback');
      expect(find.byType(FeedbackComposeForm), findsOneWidget);
      expect(menuButton, findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      await composeValidBug(tester);
      expect(find.byType(FeedbackReviewScreen), findsOneWidget);
      expect(find.byKey(FeedbackReviewScreen.backButtonKey), findsOneWidget);
      expect(menuButton, findsNothing);

      await tester.tap(find.byKey(FeedbackReviewScreen.backButtonKey));
      await tester.pumpAndSettle();
      expect(find.byType(FeedbackComposeForm), findsOneWidget);
      expect(find.text('it broke'), findsOneWidget);
      expect(menuButton, findsOneWidget);
    });

    testWidgets('beside the rail, a section shows neither the menu button '
        'nor an arrow', (tester) async {
      _useSettingsStorage();
      await pumpApp(tester, browserOwnsBack: true);
      useViewSize(tester, const Size(1000, 800));
      await tester.pumpAndSettle();
      final rail = find.byKey(NavigationShell.railKey);

      await openMenuEntry(tester, 'settings');
      // No rail on settings, so its own button carries the menu.
      expect(rail, findsNothing);
      expect(menuButton, findsOneWidget);

      await tester.tap(menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MenuDrawer.entryKey('collection')));
      await tester.pumpAndSettle();

      expect(find.byType(GameCollectionListScreen), findsOneWidget);
      expect(rail, findsOneWidget);
      final appBar = appBarOf(tester, GameCollectionListScreen);
      expect(appBar.leading, isNull);
      expect(appBar.automaticallyImplyLeading, isFalse);
    });
  });

  // PR 1 of #414 put the menu on a destination's own screen natively; the
  // rest keep their arrows there.
  testWidgets('native is unchanged', (tester) async {
    _useSettingsStorage();
    await pumpApp(tester, browserOwnsBack: false);

    await openMenuEntry(tester, 'settings');
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(menuButton, findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openMenuEntry(tester, 'households');
    expect(find.byType(BackButton), findsOneWidget);
    expect(menuButton, findsNothing);

    await tester.tap(find.byKey(HouseholdListScreen.rowKey('h-1')));
    await tester.pumpAndSettle();
    expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });
}
