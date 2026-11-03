import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A marker the collection-list builder returns, so the test can tell the
/// builder's screen from the [NotYetAvailableScreen] fallback.
const _listMarkerKey = Key('collection_list_route_marker');
const _entryMarkerKey = Key('collection_entry_route_marker');

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() => cubit = _MockAppBootstrapCubit());

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    CollectionListScreenBuilder? collectionListBuilder,
    CollectionEntryScreenBuilder? collectionEntryBuilder,
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
      collectionListBuilder: collectionListBuilder,
      collectionEntryBuilder: collectionEntryBuilder,
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

  group('buildAppRouter — collection-list route (#44)', () {
    testWidgets('resolves the collection-list builder when supplied', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        collectionListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
      );

      router.go(AppRoutes.collection);
      await tester.pumpAndSettle();

      // Also proves a ready app is not bounced off it: it is not a
      // bootstrap location.
      expect(find.byKey(_listMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.collection);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });
  });

  group('buildAppRouter — collection-entry route (#46)', () {
    testWidgets('builds the entry over the list, with the id', (tester) async {
      String? seen;
      final router = await pumpRouter(
        tester,
        collectionListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
        collectionEntryBuilder: (_, id) {
          seen = id;
          return const Scaffold(body: SizedBox(key: _entryMarkerKey));
        },
      );

      router.go(AppRoutes.collectionEntryOf('gc-1'));
      await tester.pumpAndSettle();

      expect(seen, 'gc-1');
      expect(find.byKey(_entryMarkerKey), findsOneWidget);
      // A go straight to the entry still builds the list beneath it.
      expect(find.byKey(_listMarkerKey, skipOffstage: false), findsOneWidget);
    });

    testWidgets('an id that needs encoding round-trips', (tester) async {
      String? seen;
      final router = await pumpRouter(
        tester,
        collectionEntryBuilder: (_, id) {
          seen = id;
          return const Scaffold(body: SizedBox(key: _entryMarkerKey));
        },
      );

      router.go(AppRoutes.collectionEntryOf('a b/c?d'));
      await tester.pumpAndSettle();

      expect(seen, 'a b/c?d');
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.collectionEntryOf('gc-1'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });
  });
}
