import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// Markers the builders return, so the test can tell each screen from the
/// [NotYetAvailableScreen] fallback.
const _browseKey = Key('games_route.browse');
const _searchKey = Key('games_route.search');
Key _detailKey(String id) => Key('games_route.detail_$id');

/// The #42 routes: browse, with search and one game beneath it.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() => cubit = _MockAppBootstrapCubit());

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    bool withBuilders = true,
  }) async {
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    final listenable = BootstrapStreamListenable(cubit.stream);
    final router = buildAppRouter(
      bootstrapCubit: cubit,
      refreshListenable: listenable,
      gameBrowseBuilder: withBuilders
          ? (_) => const Scaffold(body: SizedBox(key: _browseKey))
          : null,
      gameSearchBuilder: withBuilders
          ? (_) => const Scaffold(body: SizedBox(key: _searchKey))
          : null,
      gameDetailBuilder: withBuilders
          ? (_, id) => Scaffold(body: SizedBox(key: _detailKey(id)))
          : null,
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

  group('buildAppRouter — game routes (#42)', () {
    testWidgets('resolves browse', (tester) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.games);
      await tester.pumpAndSettle();

      expect(find.byKey(_browseKey), findsOneWidget);
    });

    testWidgets('resolves search, not a game whose id is "search"', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.gameSearch);
      await tester.pumpAndSettle();

      expect(find.byKey(_searchKey), findsOneWidget);
      expect(find.byKey(_detailKey('search')), findsNothing);
    });

    testWidgets('hands the detail the id from the path', (tester) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.gameDetailOf('g_catan'));
      await tester.pumpAndSettle();

      expect(find.byKey(_detailKey('g_catan')), findsOneWidget);
    });

    testWidgets('a go straight to a game builds browse beneath it', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.gameDetailOf('g_catan'));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_browseKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(tester, withBuilders: false);

      for (final location in [
        AppRoutes.games,
        AppRoutes.gameSearch,
        AppRoutes.gameDetailOf('g_catan'),
      ]) {
        router.go(location);
        await tester.pumpAndSettle();

        expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      }
    });

    test('a game id is encoded into one path segment', () {
      expect(AppRoutes.gameDetailOf('a/b c'), '/games/a%2Fb%20c');
    });
  });
}
