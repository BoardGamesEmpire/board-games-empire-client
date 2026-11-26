import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/session.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_browser_history.dart';
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

/// The server's keys, held in memory: a delete takes one away, a change of
/// enabled is kept, and every read of the list is counted.
class _FakeApiKeyRemote implements ApiKeyRemoteDataSource {
  _FakeApiKeyRemote(Iterable<ApiKey> keys)
    : _keys = {for (final key in keys) key.id: key};

  final Map<String, ApiKey> _keys;

  /// How many times page 1 of the list has been read.
  int pageReads = 0;

  @override
  Future<List<GrantablePermission>> fetchGrantable() async => const [];

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
  Future<CreatedApiKey> create(ApiKeyCreate request) =>
      throw UnimplementedError();

  @override
  Future<ApiKey> update(String id, ApiKeyPatch patch) async {
    final key = _keys[id] ?? (throw const ApiKeyNotFoundException('none'));
    return _keys[id] = key.copyWith(enabled: patch.enabled ?? key.enabled);
  }
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

  /// A signed-in server, with the API key client when [withRemote].
  ActiveServer server({required bool withRemote}) {
    final base = buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
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
  }) async {
    lease = FakeSessionLease();
    remote = _FakeApiKeyRemote([
      _key('k_1', 'CI deploy'),
      _key('k_2', 'Home dashboard'),
    ]);
    active = server(withRemote: withRemote);
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

    testWidgets('/settings/api-keys/new shows NotYetAvailableScreen until '
        'making a key is wired', (tester) async {
      final router = await pumpSettings(tester);

      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(ApiKeyDetailScreen), findsNothing);
    });

    testWidgets('a confirmed delete lands on the list', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.text('API keys'));
      await tester.pumpAndSettle();
      final readsBefore = remote.pageReads;

      await tester.tap(find.byKey(ApiKeyListScreen.rowKey('k_1')));
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeyDetailScreen), findsOneWidget);

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
  });
}
