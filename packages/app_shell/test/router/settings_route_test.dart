import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A marker the settings builder returns so the test can assert the route
/// resolved to the builder rather than the [NotYetAvailableScreen]
/// fallback.
const _settingsMarkerKey = Key('settings_route_marker');
const _exportMarkerKey = Key('export_route_marker');
const _signInMethodsMarkerKey = Key('sign_in_methods_route_marker');
const _apiKeysMarkerKey = Key('api_keys_route_marker');
const _apiKeyCreateMarkerKey = Key('api_key_create_route_marker');

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
    SettingsScreenBuilder? settingsBuilder,
    DataExportScreenBuilder? dataExportBuilder,
    SignInMethodsScreenBuilder? signInMethodsBuilder,
    ApiKeysScreenBuilder? apiKeysBuilder,
    ApiKeyDetailScreenBuilder? apiKeyDetailBuilder,
    ApiKeyCreateScreenBuilder? apiKeyCreateBuilder,
    ApiKeyCreateExit? apiKeyCreateExit,
    Stream<AppBootstrapState> states = const Stream.empty(),
  }) async {
    whenListen(cubit, states, initialState: initialState);
    final listenable = BootstrapStreamListenable(cubit.stream);
    final router = buildAppRouter(
      bootstrapCubit: cubit,
      refreshListenable: listenable,
      settingsBuilder: settingsBuilder,
      dataExportBuilder: dataExportBuilder,
      signInMethodsBuilder: signInMethodsBuilder,
      apiKeysBuilder: apiKeysBuilder,
      apiKeyDetailBuilder: apiKeyDetailBuilder,
      apiKeyCreateBuilder: apiKeyCreateBuilder,
      apiKeyCreateExit: apiKeyCreateExit,
    );
    addTearDown(() {
      router.dispose();
      listenable.dispose();
    });
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: ShellLocalizations.localizationsDelegates,
        supportedLocales: ShellLocalizations.supportedLocales,
      ),
    );
    await tester.pump();
    return router;
  }

  group('buildAppRouter — settings route (#120)', () {
    testWidgets('resolves the settings builder when ready', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when no settings builder is '
        'supplied', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('is not a bootstrap location — a ready app is not bounced off '
        'it', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    });

    testWidgets('is gated behind bootstrap: visiting it while unauthenticated '
        'redirects to auth', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });

  group('buildAppRouter — export route (#93)', () {
    testWidgets('/settings/export builds the export screen when the builder '
        'answers', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        dataExportBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _exportMarkerKey)),
      );

      router.go(AppRoutes.settingsExport);
      await tester.pumpAndSettle();

      expect(find.byKey(_exportMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailableScreen when it returns null', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        dataExportBuilder: (_) => null,
      );

      router.go(AppRoutes.settingsExport);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('Back from /settings/export returns to Settings', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
        dataExportBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _exportMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();
      unawaited(router.push(AppRoutes.settingsExport));
      await tester.pumpAndSettle();
      expect(find.byKey(_exportMarkerKey), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsOneWidget);
      expect(find.byKey(_exportMarkerKey), findsNothing);
    });
  });

  group('buildAppRouter — sign-in methods route (#582)', () {
    testWidgets('/settings/sign-in-methods builds the screen when the builder '
        'answers', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        signInMethodsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _signInMethodsMarkerKey)),
      );

      router.go(AppRoutes.settingsSignInMethods);
      await tester.pumpAndSettle();

      expect(AppRoutes.settingsSignInMethods, '/settings/sign-in-methods');
      expect(find.byKey(_signInMethodsMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailableScreen when it returns null', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        signInMethodsBuilder: (_) => null,
      );

      router.go(AppRoutes.settingsSignInMethods);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailableScreen with no builder', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go(AppRoutes.settingsSignInMethods);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('Back from /settings/sign-in-methods returns to Settings', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
        signInMethodsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _signInMethodsMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();
      unawaited(router.push(AppRoutes.settingsSignInMethods));
      await tester.pumpAndSettle();
      expect(find.byKey(_signInMethodsMarkerKey), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsOneWidget);
      expect(find.byKey(_signInMethodsMarkerKey), findsNothing);
    });

    testWidgets('is gated behind bootstrap: visiting it while unauthenticated '
        'redirects to auth', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
        signInMethodsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _signInMethodsMarkerKey)),
      );

      router.go(AppRoutes.settingsSignInMethods);
      await tester.pumpAndSettle();

      expect(find.byKey(_signInMethodsMarkerKey), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });
  group('buildAppRouter — API key routes (#1028)', () {
    /// The ids the detail builder was handed, in order.
    late List<String> detailIds;

    Widget detailMarker(String id) =>
        Scaffold(body: SizedBox(key: ValueKey('api_key_detail_marker.$id')));

    setUp(() => detailIds = []);

    Widget? recordDetail(BuildContext _, String id) {
      detailIds.add(id);
      return detailMarker(id);
    }

    testWidgets('/settings/api-keys builds the list', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeysBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeysMarkerKey)),
      );

      router.go(AppRoutes.settingsApiKeys);
      await tester.pumpAndSettle();

      expect(AppRoutes.settingsApiKeys, '/settings/api-keys');
      expect(find.byKey(_apiKeysMarkerKey), findsOneWidget);
    });

    testWidgets('the list falls back to NotYetAvailableScreen when its '
        'builder returns null', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeysBuilder: (_) => null,
      );

      router.go(AppRoutes.settingsApiKeys);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('/settings/api-keys/k_1 passes k_1 to the detail builder', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeysBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeysMarkerKey)),
        apiKeyDetailBuilder: recordDetail,
      );

      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();

      expect(AppRoutes.settingsApiKeyOf('k_1'), '/settings/api-keys/k_1');
      expect(detailIds.toSet(), {'k_1'});
      expect(
        find.byKey(const ValueKey('api_key_detail_marker.k_1')),
        findsOneWidget,
      );
    });

    testWidgets('an id is encoded into the location and decoded for the '
        'builder', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeyDetailBuilder: recordDetail,
      );

      router.go(AppRoutes.settingsApiKeyOf('a/b c'));
      await tester.pumpAndSettle();

      expect(
        AppRoutes.settingsApiKeyOf('a/b c'),
        '/settings/api-keys/a%2Fb%20c',
      );
      expect(detailIds.toSet(), {'a/b c'});
    });

    testWidgets('a key reached directly has the list beneath it, and Back '
        'returns to the list', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeysBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeysMarkerKey)),
        apiKeyDetailBuilder: recordDetail,
      );

      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();
      expect(router.canPop(), isTrue);

      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_apiKeysMarkerKey), findsOneWidget);
      expect(
        find.byKey(const ValueKey('api_key_detail_marker.k_1')),
        findsNothing,
      );
    });

    testWidgets('the detail falls back to NotYetAvailableScreen when its '
        'builder returns null', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeyDetailBuilder: (_, _) => null,
      );

      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('/settings/api-keys/new is not read as an id', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeyDetailBuilder: recordDetail,
        apiKeyCreateBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeyCreateMarkerKey)),
      );

      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();

      expect(AppRoutes.settingsApiKeyNew, '/settings/api-keys/new');
      expect(find.byKey(_apiKeyCreateMarkerKey), findsOneWidget);
      expect(detailIds, isEmpty);
    });

    testWidgets('/settings/api-keys/new builds the create screen, over the '
        'list', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeysBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeysMarkerKey)),
        apiKeyDetailBuilder: recordDetail,
        apiKeyCreateBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeyCreateMarkerKey)),
      );

      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();

      expect(find.byKey(_apiKeyCreateMarkerKey), findsOneWidget);
      expect(find.byType(NotYetAvailableScreen), findsNothing);
      // The list is beneath it, not drawn while the page covers it.
      expect(find.byKey(_apiKeysMarkerKey), findsNothing);

      // So leaving the page, by Done or by Leave, is a plain pop that lands
      // on the list, a page reached directly too.
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_apiKeyCreateMarkerKey), findsNothing);
      expect(find.byKey(_apiKeysMarkerKey), findsOneWidget);
      expect(router.state.uri.toString(), AppRoutes.settingsApiKeys);
      expect(detailIds, isEmpty);
    });

    testWidgets('/settings/api-keys/new is gated behind bootstrap: visiting '
        'it while unauthenticated redirects to auth', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
        apiKeyCreateBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeyCreateMarkerKey)),
      );

      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();

      expect(find.byKey(_apiKeyCreateMarkerKey), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    });

    group('asking the create page before it is taken away', () {
      /// How many times the router asked, and what it is told.
      late int asked;
      late bool mayLeave;

      setUp(() {
        asked = 0;
        mayLeave = true;
      });

      Widget marker(Key key) => Scaffold(body: SizedBox(key: key));

      /// A ready router with the list and the create page, which is asked
      /// through `apiKeyCreateExit`.
      Future<GoRouter> pumpGuarded(
        WidgetTester tester, {
        Stream<AppBootstrapState> states = const Stream.empty(),
      }) => pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        states: states,
        settingsBuilder: (_) => marker(_settingsMarkerKey),
        apiKeysBuilder: (_) => marker(_apiKeysMarkerKey),
        apiKeyCreateBuilder: (_) => marker(_apiKeyCreateMarkerKey),
        apiKeyCreateExit: () {
          asked++;
          return mayLeave;
        },
      );

      /// Opens the list, then pushes the create page over it, as the list's
      /// Create key does.
      Future<void> pushCreate(WidgetTester tester, GoRouter router) async {
        router.go(AppRoutes.settingsApiKeys);
        await tester.pumpAndSettle();
        unawaited(router.push<void>(AppRoutes.settingsApiKeyNew));
        await tester.pumpAndSettle();
        expect(find.byKey(_apiKeyCreateMarkerKey), findsOneWidget);
        asked = 0;
      }

      testWidgets('a go elsewhere asks, and a no keeps the page', (
        tester,
      ) async {
        final router = await pumpGuarded(tester);
        await pushCreate(tester, router);
        mayLeave = false;

        router.go(AppRoutes.settings);
        await tester.pumpAndSettle();

        expect(asked, 1);
        expect(find.byKey(_apiKeyCreateMarkerKey), findsOneWidget);
        expect(find.byKey(_settingsMarkerKey), findsNothing);

        mayLeave = true;
        router.go(AppRoutes.settings);
        await tester.pumpAndSettle();

        expect(asked, 2);
        expect(find.byKey(_apiKeyCreateMarkerKey), findsNothing);
        expect(find.byKey(_settingsMarkerKey), findsOneWidget);
      });

      testWidgets('a pop is asked about too, so a page that pops itself is '
          'asked as it goes', (tester) async {
        final router = await pumpGuarded(tester);
        await pushCreate(tester, router);
        mayLeave = false;

        router.pop();
        await tester.pumpAndSettle();

        expect(asked, 1);
        expect(find.byKey(_apiKeyCreateMarkerKey), findsOneWidget);

        mayLeave = true;
        router.pop();
        await tester.pumpAndSettle();

        expect(asked, 2);
        expect(find.byKey(_apiKeyCreateMarkerKey), findsNothing);
        expect(find.byKey(_apiKeysMarkerKey), findsOneWidget);
      });

      testWidgets('a page pushed over it is no leaving, and asks nothing', (
        tester,
      ) async {
        final router = await pumpGuarded(tester);
        await pushCreate(tester, router);

        unawaited(router.push<void>(AppRoutes.settings));
        await tester.pumpAndSettle();

        expect(asked, 0);
        expect(find.byKey(_settingsMarkerKey), findsOneWidget);
      });

      testWidgets('the router re-reading its location for a bootstrap '
          'change asks nothing, with the page pushed', (tester) async {
        final states = StreamController<AppBootstrapState>();
        addTearDown(states.close);
        final router = await pumpGuarded(tester, states: states.stream);
        await pushCreate(tester, router);
        // Were it asked, the answer would hold the page: it must not be.
        mayLeave = false;

        states.add(const AppBootstrapReady());
        await tester.pumpAndSettle();

        expect(asked, 0);
        expect(find.byKey(_apiKeyCreateMarkerKey), findsOneWidget);

        // And asking is back once the re-read is done.
        router.go(AppRoutes.settings);
        await tester.pumpAndSettle();
        expect(asked, 1);
        expect(find.byKey(_apiKeyCreateMarkerKey), findsOneWidget);
      });

      testWidgets('the bootstrap redirect as a session ends asks nothing, '
          'whatever the page would say', (tester) async {
        final states = StreamController<AppBootstrapState>();
        addTearDown(states.close);
        final router = await pumpGuarded(tester, states: states.stream);
        await pushCreate(tester, router);
        mayLeave = false;

        states.add(const AppBootstrapNeedsAuth());
        await tester.pumpAndSettle();

        expect(asked, 0);
        expect(find.byKey(_apiKeyCreateMarkerKey), findsNothing);
        expect(find.text('Sign in'), findsOneWidget);
        expect(router.state.uri.path, AppRoutes.auth);
      });
    });

    testWidgets('/settings/api-keys/new falls back to NotYetAvailableScreen '
        'with no create builder, still not as an id', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        apiKeyDetailBuilder: recordDetail,
      );

      router.go(AppRoutes.settingsApiKeyNew);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(detailIds, isEmpty);
    });

    testWidgets('is gated behind bootstrap: visiting it while unauthenticated '
        'redirects to auth', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
        apiKeysBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _apiKeysMarkerKey)),
        apiKeyDetailBuilder: recordDetail,
      );

      router.go(AppRoutes.settingsApiKeyOf('k_1'));
      await tester.pumpAndSettle();

      expect(find.byKey(_apiKeysMarkerKey), findsNothing);
      expect(detailIds, isEmpty);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });
}
