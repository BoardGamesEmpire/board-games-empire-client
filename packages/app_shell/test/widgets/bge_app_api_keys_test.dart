import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_browser_history.dart';
import '../support/navigation.dart';
import '../support/no_later_recoveries.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    with NoLaterRecoveries
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

/// Answers with whichever server the test made active last.
class _SwitchableScope implements ActiveServerScope {
  _SwitchableScope(this._read);

  final ActiveServer Function() _read;

  @override
  ActiveServer? get active => _read();

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(_read());
}

/// The secret the fake server answers a create with.
const _secret = 'bge_s3cr3t_a1B2c3D4e5F6';

/// The server's keys, held in memory: a create adds one, a delete takes one
/// away, a change of enabled is kept, and every read of the list is counted.
class _FakeApiKeyRemote implements ApiKeyRemoteDataSource {
  _FakeApiKeyRemote(Iterable<ApiKey> keys)
    : _keys = {for (final key in keys) key.id: key};

  final Map<String, ApiKey> _keys;

  /// How many times page 1 of the list has been read.
  int pageReads = 0;

  /// Every create asked for, in order.
  final List<ApiKeyCreate> creates = [];

  /// When set, a create waits on it before the server answers.
  Completer<void>? holdCreate;

  @override
  Future<List<GrantablePermission>> fetchGrantable() async => const [
    GrantablePermission(
      slug: 'collection:read',
      description: 'Read your game collection',
      riskLevel: RiskLevel.low,
      pinnable: false,
    ),
    GrantablePermission(
      slug: 'users:manage',
      description: 'Manage every user',
      riskLevel: RiskLevel.critical,
      pinnable: false,
    ),
  ];

  @override
  Future<PaginatedResult<ApiKey>> fetchPage({
    int page = 1,
    int limit = ApiKeyRemoteDataSource.defaultPageSize,
  }) async {
    if (page == 1) pageReads++;
    final items = _keys.values.toList();
    return PaginatedResult(
      items: items,
      meta: PaginationMeta(
        page: page,
        limit: limit,
        total: items.length,
        totalPages: 1,
        hasMore: false,
      ),
    );
  }

  @override
  Future<ApiKey> fetch(String id) async =>
      _keys[id] ?? (throw const ApiKeyNotFoundException('not found'));

  @override
  Future<void> delete(String id) async {
    if (_keys.remove(id) == null) {
      throw const ApiKeyNotFoundException('not found');
    }
  }

  @override
  Future<CreatedApiKey> create(ApiKeyCreate request) async {
    creates.add(request);
    await holdCreate?.future;
    final key = _key('k_new', request.name);
    _keys[key.id] = key;
    return CreatedApiKey(apiKey: key, secret: _secret);
  }

  @override
  Future<ApiKey> update(String id, ApiKeyPatch patch) async {
    final key = _keys[id] ?? (throw const ApiKeyNotFoundException('none'));
    return _keys[id] = key.copyWith(enabled: patch.enabled ?? key.enabled);
  }
}

/// A collection cache holding nothing, whose watch stays open, as Drift's
/// does. With [_Events], it gives the session destinations, so the
/// navigation shell shows its bar or rail.
class _Collection implements GameCollectionRepository {
  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() =>
      Stream.multi((stream) => stream.add(const []));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// An event cache holding nothing.
class _Events implements EventRepository {
  @override
  Stream<List<EventListItem>> watchAttendingEventListItems() =>
      Stream.multi((stream) => stream.add(const []));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

ApiKey _key(String id, String name) => ApiKey(
  id: id,
  name: name,
  start: 'bge_a1B2',
  scopes: const [ApiKeyScope(slug: 'collection:read')],
  enabled: true,
  createdAt: DateTime.utc(2026, 11),
);

/// The #1028 wiring that lives inside [BgeApp]: that it offers the Settings
/// row where the server has the API key client, hands the route builders to
/// the router, and leaves a key's page for the list. The router and entry
/// tests use stand-ins and cannot see those lines.
void main() {
  late _MockAppBootstrapCubit cubit;
  late StreamController<AppBootstrapState> states;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    states = StreamController<AppBootstrapState>();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  tearDown(() => states.close());

  /// The session lease the active server's container answers with, read
  /// whenever the shell asks for it.
  late SessionLease lease;

  /// The active server, read whenever the shell asks for it.
  late ActiveServer active;

  /// The active server's API key client, when it has one.
  late _FakeApiKeyRemote remote;

  /// A signed-in server, with the API key client when [withRemote], and
  /// with a collection and events, so a bar or rail to pick them on, when
  /// [destinations].
  ActiveServer server({required bool withRemote, bool destinations = false}) {
    final base = buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
      gameCollectionRepository: destinations ? _Collection() : null,
      eventRepository: destinations ? _Events() : null,
    );
    base.container.registerFactory<SessionLease>(() => lease);
    if (withRemote) {
      base.container.registerSingleton<ApiKeyRemoteDataSource>(remote);
    }
    return base;
  }

  /// Boots the app into a session and goes to Settings. With [web], the
  /// browser owns Back, as it does in the browser app: no page shows a back
  /// arrow of its own.
  Future<GoRouter> pumpSettings(
    WidgetTester tester, {
    bool withRemote = true,
    bool web = false,
    bool destinations = false,
  }) async {
    lease = FakeSessionLease();
    remote = _FakeApiKeyRemote([
      _key('k_1', 'CI deploy'),
      _key('k_2', 'Home dashboard'),
    ]);
    active = server(withRemote: withRemote, destinations: destinations);
    when(() => cubit.activeServerScope).thenReturn(
      _SwitchableScope(() => active),
    );
    whenListen(
      cubit,
      states.stream,
      initialState: const AppBootstrapInitializing(),
    );
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, browserOwnsBack: web),
    );
    await tester.pump();
    states.add(const AppBootstrapReady());
    await tester.pumpAndSettle();
    final router =
        tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter
          ..go(AppRoutes.settings);
    await tester.pumpAndSettle();
    return router;
  }

  Finder createFab() => find.byKey(ApiKeyListScreen.createFabKey);

  ApiKeyCreateScreen createPage(WidgetTester tester) =>
      tester.widget<ApiKeyCreateScreen>(find.byType(ApiKeyCreateScreen));

  /// Opens the list from Settings, then the page that makes a key from
  /// the list's Create key.
  Future<void> openCreate(WidgetTester tester) async {
    await tester.tap(find.text('API keys'));
    await tester.pumpAndSettle();
    await tester.tap(createFab());
    await tester.pumpAndSettle();
    expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
  }

  /// Names a key on the open page and creates it, to its secret.
  Future<void> makeKey(WidgetTester tester) async {
    await tester.enterText(find.byKey(ApiKeyCreateScreen.nameKey), 'Backup');
    await tester.pumpAndSettle();
    final create = find.byKey(ApiKeyCreateScreen.submitKey);
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.text(_secret), findsOneWidget);
  }

  group('API keys (#1028)', () {
    testWidgets('a server with the remote shows the API keys row', (
      tester,
    ) async {
      await pumpSettings(tester);

      expect(find.byKey(const Key('settings_api_keys')), findsOneWidget);
      expect(find.text('API keys'), findsOneWidget);
      // The identity's name, not the display name ("My Server").
      expect(
        find.text('Keys for programs to use Test BGE Server as you'),
        findsOneWidget,
      );
    });

    testWidgets('a server without it shows none', (tester) async {
      final router = await pumpSettings(tester, withRemote: false);

      expect(find.byType(SettingsScreen), findsOneWidget);
      // The server's own section is there, with sign-in methods in it.
      expect(find.text('Sign-in methods'), findsOneWidget);
      expect(find.byKey(const Key('settings_api_keys')), findsNothing);

      router.go(AppRoutes.settingsApiKeys);
      await tester.pumpAndSettle();
      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(ApiKeyListScreen), findsNothing);

      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyDetailScreen), findsNothing);

      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();
      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
    });

    testWidgets("the row opens the list over the active server's remote", (
      tester,
    ) async {
      await pumpSettings(tester);

      await tester.tap(find.text('API keys'));
      await tester.pumpAndSettle();

      final list = tester.widget<ApiKeyListScreen>(
        find.byType(ApiKeyListScreen),
      );
      expect(list.remote, same(remote));
      expect(list.createKey, isNotNull);
      expect(list.key, ValueKey((active, lease)));
      expect(find.text('CI deploy'), findsOneWidget);
      expect(find.text('Home dashboard'), findsOneWidget);
    });

    testWidgets("a key's page reads the key, with the session's lease", (
      tester,
    ) async {
      final router = await pumpSettings(tester);

      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();

      final detail = tester.widget<ApiKeyDetailScreen>(
        find.byType(ApiKeyDetailScreen),
      );
      expect(detail.remote, same(remote));
      expect(detail.id, 'k_1');
      expect(detail.sessionLease, same(lease));
      expect(detail.key, ValueKey((active, lease)));
    });

    testWidgets('a confirmed delete lands on the list', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.text('API keys'));
      await tester.pumpAndSettle();
      final readsBefore = remote.pageReads;

      await tester.tap(find.byKey(ApiKeyListScreen.rowKey('k_1')));
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyDetailScreen), findsOneWidget);

      // Delete sits below the key's edit form.
      await tester.ensureVisible(find.byKey(ApiKeyDetailScreen.deleteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyDetailScreen.deleteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(DeleteKeyDialog.confirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyDetailScreen), findsNothing);
      expect(find.byType(ApiKeyListScreen), findsOneWidget);
      // The list read itself again, and the key is gone from it.
      expect(remote.pageReads, greaterThan(readsBefore));
      expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsNothing);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_2')), findsOneWidget);
    });

    testWidgets('a key reached directly has the list beneath it, and the gone '
        "page's Back lands there", (tester) async {
      final router = await pumpSettings(tester);

      router.go(AppRoutes.settingsApiKeyOf('k_gone'));
      await tester.pumpAndSettle();
      expect(find.byKey(ApiKeyDetailScreen.goneKey), findsOneWidget);

      await tester.tap(find.byKey(ApiKeyDetailScreen.backKey));
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyDetailScreen), findsNothing);
      expect(find.byType(ApiKeyListScreen), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeys);
    });

    testWidgets('a key reached directly and deleted lands on a list that has '
        'read itself again', (tester) async {
      final router = await pumpSettings(tester);
      // As a link or a reload opens it: the list is built beneath, and reads
      // the keys there are then.
      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();
      final readsBefore = remote.pageReads;

      // Below the key's form, so out of view.
      await tester.ensureVisible(find.byKey(ApiKeyDetailScreen.deleteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyDetailScreen.deleteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(DeleteKeyDialog.confirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyListScreen), findsOneWidget);
      expect(remote.pageReads, readsBefore + 1);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsNothing);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_2')), findsOneWidget);
    });

    testWidgets('a key reached directly and disabled shows so on the list '
        'its Back lands on', (tester) async {
      final router = await pumpSettings(tester);
      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();
      final readsBefore = remote.pageReads;

      // Below the key's form, so out of view.
      await tester.ensureVisible(find.byKey(ApiKeyDetailScreen.enabledKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyDetailScreen.enabledKey));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Programs using this key are refused until you enable it again.',
        ),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyListScreen), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeys);
      expect(remote.pageReads, readsBefore + 1);
      expect(
        find.descendant(
          of: find.byKey(ApiKeyListScreen.rowKey('k_1')),
          matching: find.text('Disabled'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a new session gets a fresh list', (tester) async {
      final router = await pumpSettings(tester);
      router.go(AppRoutes.settingsApiKeys);
      await tester.pumpAndSettle();
      State<ApiKeyListScreen> listState() =>
          tester.state(find.byType(ApiKeyListScreen));
      final first = listState();

      // Another session on the same server container: the remote is the
      // same object, so only the lease tells the lists apart.
      lease = FakeSessionLease();
      unawaited(router.push(AppRoutes.settings));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(
        tester.widget<ApiKeyListScreen>(find.byType(ApiKeyListScreen)).key,
        ValueKey((active, lease)),
      );
      expect(listState(), isNot(same(first)));
      expect(first.mounted, isFalse);
    });
  });

  group('making an API key (#1028)', () {
    testWidgets("the list's Create key opens the page over the active "
        "server's remote", (tester) async {
      final router = await pumpSettings(tester);

      await openCreate(tester);

      expect(createPage(tester).remote, same(remote));
      expect(createPage(tester).key, ValueKey((active, lease)));
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);
      expect(find.byType(NotYetAvailableScreen), findsNothing);
    });

    testWidgets('/settings/api-keys/new reached directly has the list '
        'beneath it', (tester) async {
      final router = await pumpSettings(tester);

      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(find.byType(ApiKeyDetailScreen), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.byType(ApiKeyListScreen), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeys);
    });

    testWidgets('a key made on a page reached directly is on the list '
        'Done lands on', (tester) async {
      final router = await pumpSettings(tester);
      // As a link or a reload opens it: the list is built beneath, and
      // reads the keys there are then.
      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();
      final readsBefore = remote.pageReads;
      await makeKey(tester);

      final done = find.byKey(SecretPanel.doneKey);
      await tester.ensureVisible(done);
      await tester.pumpAndSettle();
      await tester.tap(done);
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyListScreen), findsOneWidget);
      expect(remote.pageReads, readsBefore + 1);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);
    });

    testWidgets('a key made there shows its secret, and Done lands on the '
        'list, which has read itself again', (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      final readsBefore = remote.pageReads;

      await makeKey(tester);

      expect(remote.creates.single.name, 'Backup');
      // In place: the same page at the same address.
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);
      expect(find.byType(SecretPanel), findsOneWidget);

      final done = find.byKey(SecretPanel.doneKey);
      await tester.ensureVisible(done);
      await tester.pumpAndSettle();
      await tester.tap(done);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(_secret), findsNothing);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeys);
      // Once: the page going is one return, whichever sign of it came first.
      expect(remote.pageReads, readsBefore + 1);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);
    });

    /// Each Back the app itself hears, which the page can refuse.
    final backs = <String, Future<void> Function(WidgetTester)>{
      "the page's back arrow": (tester) => tester.pageBack(),
      // Through the navigation shell's own handler, then the router.
      'System Back': (tester) => tester.binding.handlePopRoute(),
    };

    for (final MapEntry(key: way, value: goBack) in backs.entries) {
      testWidgets('$way from the secret asks first: Stay keeps it, and '
          'Leave lands on the list', (tester) async {
        final router = await pumpSettings(tester);
        await openCreate(tester);
        await makeKey(tester);

        await goBack(tester);
        await tester.pumpAndSettle();

        expect(find.text('Leave without copying?'), findsOneWidget);
        expect(find.text("You won't see this key again."), findsOneWidget);
        expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
        expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

        await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(_secret), findsOneWidget);
        expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

        await goBack(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
        await tester.pumpAndSettle();

        // Leave was the answer: the router, which is asked as it carries
        // the page's pop out, asks nothing again.
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(ApiKeyCreateScreen), findsNothing);
        expect(find.text(_secret), findsNothing);
        expect(find.byType(ApiKeyListScreen), findsOneWidget);
        expect(router.state.uri.toString(), AppRoutes.settingsApiKeys);
        expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);
      });
    }

    testWidgets('System Back on the question closes the question, not the '
        'page', (tester) async {
      await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Leave without copying?'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_secret), findsOneWidget);
    });

    testWidgets('a window that changes class under the secret keeps it', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 800));
      await pumpSettings(tester, destinations: true);
      await openCreate(tester);
      await makeKey(tester);
      final panel = tester.state(find.byType(SecretPanel));

      // A phone turned on its side, then a desktop window: the shell swaps
      // its bar for a rail, and the page keeps its state through both.
      for (final size in const [Size(800, 400), Size(1280, 800)]) {
        useViewSize(tester, size);
        await tester.pumpAndSettle();

        expect(find.text(_secret), findsOneWidget, reason: '$size');
        expect(tester.state(find.byType(SecretPanel)), same(panel));
      }
      expect(remote.creates, hasLength(1));
    });

    testWidgets('a page opened over the secret leaves it there to come '
        'back to', (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);

      unawaited(router.push(AppRoutes.settings));
      await tester.pumpAndSettle();
      expect(find.text(_secret), findsNothing);
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_secret), findsOneWidget);
      expect(remote.creates, hasLength(1));
    });

    testWidgets('a new session gets a fresh page, without the last '
        "session's secret", (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);

      // Another session on the same server container: the remote is the
      // same object, so only the lease tells the pages apart.
      lease = FakeSessionLease();
      unawaited(router.push(AppRoutes.settings));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(createPage(tester).key, ValueKey((active, lease)));
      expect(find.text(_secret), findsNothing);
      expect(find.byType(SecretPanel), findsNothing);
      expect(find.byKey(ApiKeyCreateScreen.nameKey), findsOneWidget);
    });

    // A move to another location pops nothing: the router takes the page
    // away. So the page can't refuse it, and the router asks the page
    // before it does (`GoRoute.onExit`).
    testWidgets('a pick in the menu from the secret asks first: Stay keeps '
        'it, and Leave goes where the pick went', (tester) async {
      useViewSize(tester, const Size(400, 800));
      final router = await pumpSettings(tester, destinations: true);
      await openCreate(tester);
      await makeKey(tester);

      await openMenuEntry(tester, 'collection');

      expect(find.text('Leave without copying?'), findsOneWidget);
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_secret), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);
      expect(find.byType(MenuDrawer), findsNothing);

      await openMenuEntry(tester, 'collection');
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(_secret), findsNothing);
      expect(router.state.uri.path, AppRoutes.collection);
    });

    testWidgets('a move elsewhere from the form, with nothing to lose, asks '
        'nothing', (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      await tester.enterText(find.byKey(ApiKeyCreateScreen.nameKey), 'Backup');
      await tester.pumpAndSettle();

      router.go(AppRoutes.home);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(router.state.uri.path, AppRoutes.home);
    });

    testWidgets('a key on its way holds the page against a move elsewhere, '
        'and nothing is asked', (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      remote.holdCreate = Completer<void>();
      await tester.enterText(find.byKey(ApiKeyCreateScreen.nameKey), 'Backup');
      await tester.pumpAndSettle();
      final create = find.byKey(ApiKeyCreateScreen.submitKey);
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.tap(create);
      // Busy: its spinner never settles.
      await tester.pump();
      await tester.pump();
      expect(find.text('Creating key…'), findsOneWidget);

      router.go(AppRoutes.home);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

      // So the answer has a page to arrive on, and is not lost.
      remote.holdCreate!.complete();
      await tester.pumpAndSettle();
      expect(find.text(_secret), findsOneWidget);
      expect(remote.creates, hasLength(1));
    });

    testWidgets("a move elsewhere while Back's question is open asks "
        'nothing more, and waits on the one answer', (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Leave without copying?'), findsOneWidget);

      router.go(AppRoutes.home);
      await tester.pumpAndSettle();

      expect(find.text('Leave without copying?'), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      // Stay answers both: the pop and the move.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_secret), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

      await tester.pageBack();
      await tester.pumpAndSettle();
      router.go(AppRoutes.home);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
      await tester.pumpAndSettle();

      // And Leave answers both: the question is gone with the page, and
      // the move went where it was going.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(router.state.uri.path, AppRoutes.home);
    });

    testWidgets('a move elsewhere while the Critical question is open takes '
        'the form and the question with it, and sends nothing', (
      tester,
    ) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      await tester.enterText(find.byKey(ApiKeyCreateScreen.nameKey), 'Backup');
      await tester.pumpAndSettle();
      final critical = find.text('Manage every user');
      await tester.ensureVisible(critical);
      await tester.pumpAndSettle();
      await tester.tap(critical);
      await tester.pumpAndSettle();
      final create = find.byKey(ApiKeyCreateScreen.submitKey);
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.byType(CriticalConfirmDialog), findsOneWidget);

      router.go(AppRoutes.home);
      await tester.pumpAndSettle();

      // Nothing was on its way, so nothing held the form. Its question is
      // on the root navigator, and leaves with the page it was asked over.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(router.state.uri.path, AppRoutes.home);
      expect(remote.creates, isEmpty);
    });

    // go_router re-reads its location when the bootstrap cubit emits, and
    // gives a pushed page a new match each time. It takes that for the page
    // leaving and asks the route's `onExit`, though the page goes nowhere.
    // The router lets its own re-read through unasked.
    testWidgets('the router re-reading its location is no leaving: it asks '
        'nothing, and the key stays', (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);
      final panel = tester.state(find.byType(SecretPanel));

      states.add(const AppBootstrapReady());
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_secret), findsOneWidget);
      expect(tester.state(find.byType(SecretPanel)), same(panel));
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

      // And the page is as guarded as it was.
      router.go(AppRoutes.home);
      await tester.pumpAndSettle();
      expect(find.text('Leave without copying?'), findsOneWidget);
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Leave without copying?'), findsOneWidget);
    });

    testWidgets('once the session has ended, a move elsewhere takes the '
        'page unasked', (tester) async {
      final router = await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);

      // As the shell ends a session in place: the lease first, then the
      // move, in one turn.
      (lease as FakeSessionLease).isLive = false;
      router.go(AppRoutes.home);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(_secret), findsNothing);
    });

    testWidgets("a session that ends while Back's question is open takes "
        'the question with the page', (tester) async {
      await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Leave without copying?'), findsOneWidget);

      states.add(const AppBootstrapNeedsAuth());
      // The sign-in page never settles. The shell leaves over its exit, and
      // the router's modal guard takes the question down the frame after.
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(_secret), findsNothing);
    });

    testWidgets('a session that ends takes the page and its secret, and '
        'asks nothing', (tester) async {
      await pumpSettings(tester);
      await openCreate(tester);
      await makeKey(tester);

      states.add(const AppBootstrapNeedsAuth());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(_secret), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group("API keys under the browser's Back (#1028)", () {
    testWidgets("Back from a key's page reads the list again, and the list "
        'opens another', (tester) async {
      final history = FakeBrowserHistory.install(tester);
      await pumpSettings(tester, web: true);
      await tester.tap(find.text('API keys'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyListScreen.rowKey('k_1')));
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyDetailScreen), findsOneWidget);
      expect(history.locations.last, AppRoutes.settingsApiKeyOf('k_1'));
      final readsBefore = remote.pageReads;

      await history.back();

      expect(find.byType(ApiKeyDetailScreen), findsNothing);
      expect(history.locations.last, AppRoutes.settingsApiKeys);
      expect(remote.pageReads, greaterThan(readsBefore));

      // The push that opened the page never completes when the browser
      // takes the page away. The list is not left waiting on it.
      await tester.tap(find.byKey(ApiKeyListScreen.rowKey('k_2')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ApiKeyDetailScreen>(find.byType(ApiKeyDetailScreen)).id,
        'k_2',
      );
    });

    testWidgets('Back from the form lands on the list, which opens it '
        'again', (tester) async {
      final history = FakeBrowserHistory.install(tester);
      await pumpSettings(tester, web: true);
      await tester.tap(find.text('API keys'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyListScreen.createFabKey));
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(history.locations.last, AppRoutes.settingsApiKeyNew);
      // The browser's Back is the way back: the page shows no arrow.
      expect(find.byTooltip('Back'), findsNothing);

      await history.back();

      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(history.locations.last, AppRoutes.settingsApiKeys);

      await tester.tap(find.byKey(ApiKeyListScreen.createFabKey));
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
    });

    testWidgets("after Done, Back onto the page's address opens the form, "
        'never the key', (tester) async {
      final history = FakeBrowserHistory.install(tester);
      await pumpSettings(tester, web: true);
      await openCreate(tester);
      await makeKey(tester);
      final done = find.byKey(SecretPanel.doneKey);
      await tester.ensureVisible(done);
      await tester.pumpAndSettle();
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyListScreen), findsOneWidget);
      expect(history.locations.last, AppRoutes.settingsApiKeys);

      // Leaving added an entry, so the page's own is one Back away.
      await history.back();

      expect(history.locations.last, AppRoutes.settingsApiKeyNew);
      // Nothing restores the secret: it went with the page's bloc.
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(find.byKey(ApiKeyCreateScreen.nameKey), findsOneWidget);
      expect(find.byType(SecretPanel), findsNothing);
      expect(find.text(_secret), findsNothing);
      expect(remote.creates, hasLength(1));
      // And no address the router gave the browser ever held it.
      expect(
        history.reported.where((location) => location.contains(_secret)),
        isEmpty,
      );
    });

    // The browser's Back pops nothing: the router is handed another
    // location and takes the page away. So the page can't refuse it, and
    // the router asks the page before it does (`GoRoute.onExit`).
    testWidgets('Back from the secret asks first, and Stay keeps the key at '
        'its own address', (tester) async {
      final history = FakeBrowserHistory.install(tester);
      final router = await pumpSettings(tester, web: true);
      await openCreate(tester);
      await makeKey(tester);
      // The browser's Back is the only way back there: no arrow.
      expect(find.byTooltip('Back'), findsNothing);
      final before = history.locations;
      expect(before.last, AppRoutes.settingsApiKeyNew);

      await history.back();

      expect(find.text('Leave without copying?'), findsOneWidget);
      expect(find.text("You won't see this key again."), findsOneWidget);
      // Held: the router has taken nothing.
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_secret), findsOneWidget);
      // The browser had moved its address back. The router puts the page's
      // own back, as the entry after the list's, where it was.
      expect(history.locations, before);
      expect(history.allLocations, before);
      expect(remote.creates, hasLength(1));
    });

    testWidgets('Back asks each time it is pressed, Leave lands on the '
        'list, and Forward brings back the form, never the key', (
      tester,
    ) async {
      final history = FakeBrowserHistory.install(tester);
      await pumpSettings(tester, web: true);
      await openCreate(tester);
      await makeKey(tester);
      await history.back();
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      await history.back();
      expect(find.text('Leave without copying?'), findsOneWidget);
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
      await tester.pumpAndSettle();

      // Asked once for this Back: Leave was the answer, and nothing asks
      // again as the page goes.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(_secret), findsNothing);
      expect(history.locations.last, AppRoutes.settingsApiKeys);
      // The key was made, and is on the list the user lands on.
      expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);

      await history.forward();

      expect(history.locations.last, AppRoutes.settingsApiKeyNew);
      expect(find.byKey(ApiKeyCreateScreen.nameKey), findsOneWidget);
      expect(find.byType(SecretPanel), findsNothing);
      expect(find.text(_secret), findsNothing);

      // And the form, with nothing to lose, goes without a question.
      await history.back();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyListScreen), findsOneWidget);
    });

    testWidgets('a second Back while the question is open asks nothing '
        'more', (tester) async {
      final history = FakeBrowserHistory.install(tester);
      final router = await pumpSettings(tester, web: true);
      await openCreate(tester);
      await makeKey(tester);

      await history.back();
      await history.back();

      expect(find.text('Leave without copying?'), findsOneWidget);
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      // One answer for both.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_secret), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);
      expect(history.locations.last, AppRoutes.settingsApiKeyNew);
    });

    testWidgets('a key on its way holds the page against another location '
        'from the browser, and nothing is asked', (tester) async {
      FakeBrowserHistory.install(tester);
      final router = await pumpSettings(tester, web: true);
      await openCreate(tester);
      remote.holdCreate = Completer<void>();
      await tester.enterText(find.byKey(ApiKeyCreateScreen.nameKey), 'Backup');
      await tester.pumpAndSettle();
      final create = find.byKey(ApiKeyCreateScreen.submitKey);
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.tap(create);
      // Busy: its spinner never settles.
      await tester.pump();
      await tester.pump();
      expect(find.text('Creating key…'), findsOneWidget);

      // As the browser hands the router the list's address, on Back.
      await router.routeInformationProvider.didPushRouteInformation(
        RouteInformation(uri: Uri.parse(AppRoutes.settingsApiKeys)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeyNew);

      // So the answer has a page to arrive on.
      remote.holdCreate!.complete();
      await tester.pumpAndSettle();
      expect(find.text(_secret), findsOneWidget);
    });
  });
}
