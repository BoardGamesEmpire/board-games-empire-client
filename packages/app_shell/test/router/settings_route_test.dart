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
  }) async {
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: initialState,
    );
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
