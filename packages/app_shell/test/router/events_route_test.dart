import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:events/events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// Markers the builders return, so the test can tell each screen from the
/// [NotYetAvailableScreen] fallback.
const _overviewKey = Key('events_route.overview');
Key _groupKey(String segment) => Key('events_route.group_$segment');

/// The #497 routes: the overview, with a page per group beneath it.
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
      eventOverviewBuilder: withBuilders
          ? (_) => const Scaffold(body: SizedBox(key: _overviewKey))
          : null,
      eventGroupBuilder: withBuilders
          ? (_, segment) => Scaffold(body: SizedBox(key: _groupKey(segment)))
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

  group('buildAppRouter — event routes (#497)', () {
    testWidgets('resolves the overview builder', (tester) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.events);
      await tester.pumpAndSettle();

      // Also proves a ready app is not bounced off it: it is not a
      // bootstrap location.
      expect(find.byKey(_overviewKey), findsOneWidget);
    });

    testWidgets('resolves each group segment to the group builder with that '
        'segment', (tester) async {
      final router = await pumpRouter(tester);

      for (final segment in AppRoutes.eventGroupSegments) {
        router.go(AppRoutes.eventGroupOf(segment));
        await tester.pumpAndSettle();

        expect(find.byKey(_groupKey(segment)), findsOneWidget, reason: segment);
      }
    });

    testWidgets('a go straight to a group builds the overview beneath it', (
      tester,
    ) async {
      // So a cold entry at a group's page has somewhere to go back to, as
      // the household children have (#308).
      final router = await pumpRouter(tester);

      router.go(AppRoutes.eventGroupOf('past'));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_overviewKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable without builders', (
      tester,
    ) async {
      final router = await pumpRouter(tester, withBuilders: false);

      for (final location in [
        AppRoutes.events,
        AppRoutes.eventGroupOf('upcoming'),
      ]) {
        router.go(location);
        await tester.pumpAndSettle();

        expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      }
    });

    test('the segments are the EventGroup names', () {
      // The shell maps a segment back to its group by name, so the two
      // lists must not drift apart.
      expect(
        AppRoutes.eventGroupSegments,
        EventGroup.values.map((g) => g.name).toList(),
      );
      expect(AppRoutes.eventGroupOf('planning'), '/events/planning');
    });
  });
}
