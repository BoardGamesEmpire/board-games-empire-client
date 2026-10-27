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
Key _detailKey(String eventId) => Key('events_route.detail_$eventId');

/// The create form's marker, naming the household its builder was handed,
/// if any.
Key _createKey([String? householdId]) => Key(
  householdId == null
      ? 'events_route.create'
      : 'events_route.create_$householdId',
);

/// The #497 routes: the overview, with a page per group beneath it, #498's
/// event detail beneath that, and #499's create form beside the groups.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() => cubit = _MockAppBootstrapCubit());

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    bool withBuilders = true,
    bool withDetailBuilder = true,
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
      eventCreateBuilder: withBuilders
          ? (_, householdId) =>
                Scaffold(body: SizedBox(key: _createKey(householdId)))
          : null,
      eventDetailBuilder: withBuilders && withDetailBuilder
          ? (_, eventId) => Scaffold(body: SizedBox(key: _detailKey(eventId)))
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

  group('buildAppRouter — event routes (#497, #498, #499)', () {
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

    testWidgets('resolves an event id to the detail builder with that id', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.eventDetailOf('e-1'));
      await tester.pumpAndSettle();

      expect(find.byKey(_detailKey('e-1')), findsOneWidget);
    });

    testWidgets('the group pages still win over the detail', (tester) async {
      // `upcoming` is a legal event id. The detail is declared after the
      // group pages, so each segment must reach its group and never the
      // detail.
      final router = await pumpRouter(tester);

      for (final segment in AppRoutes.eventGroupSegments) {
        router.go(AppRoutes.eventGroupOf(segment));
        await tester.pumpAndSettle();

        expect(find.byKey(_groupKey(segment)), findsOneWidget, reason: segment);
        expect(find.byKey(_detailKey(segment)), findsNothing, reason: segment);
      }
    });

    testWidgets('a go straight to an event builds the overview beneath it', (
      tester,
    ) async {
      // So a cold entry at an event has somewhere to go back to, as the
      // group pages have.
      final router = await pumpRouter(tester);

      router.go(AppRoutes.eventDetailOf('e-1'));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_overviewKey), findsOneWidget);
      expect(find.byKey(_detailKey('e-1')), findsNothing);
    });

    testWidgets('an id with a slash is encoded', (tester) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.eventDetailOf('a/b'));
      await tester.pumpAndSettle();

      expect(find.byKey(_detailKey('a/b')), findsOneWidget);
    });

    testWidgets('/events/create is the form, not an event called create', (
      tester,
    ) async {
      // `create` is a legal event id. The form is declared before the
      // detail, so the path must reach the form and never the detail.
      final router = await pumpRouter(tester);

      router.go(AppRoutes.eventCreate);
      await tester.pumpAndSettle();

      expect(find.byKey(_createKey()), findsOneWidget);
      expect(find.byKey(_detailKey('create')), findsNothing);
    });

    testWidgets('/events/create?household=h1 prefills the household', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go('/events/create?household=h1');
      await tester.pumpAndSettle();

      expect(find.byKey(_createKey('h1')), findsOneWidget);
    });

    testWidgets('an empty household is none', (tester) async {
      final router = await pumpRouter(tester);

      router.go('/events/create?household=');
      await tester.pumpAndSettle();

      expect(find.byKey(_createKey()), findsOneWidget);
    });

    testWidgets('eventCreateOf encodes the household id', (tester) async {
      final router = await pumpRouter(tester);

      // Unencoded, `&` and `#` would end the value early, and `+` would read
      // back as a space.
      const id = 'a b&c=d#e+f';
      router.go(AppRoutes.eventCreateOf(householdId: id));
      await tester.pumpAndSettle();

      expect(find.byKey(_createKey(id)), findsOneWidget);
      // Without one it is the form's own location.
      expect(AppRoutes.eventCreateOf(), AppRoutes.eventCreate);
    });

    testWidgets('a go straight to the form builds the overview beneath it', (
      tester,
    ) async {
      // So back from the form, or from the event that replaces it, is the
      // overview.
      final router = await pumpRouter(tester);

      router.go(AppRoutes.eventCreate);
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_overviewKey), findsOneWidget);
      expect(find.byKey(_createKey()), findsNothing);
    });

    testWidgets('falls back to NotYetAvailable without builders', (
      tester,
    ) async {
      final router = await pumpRouter(tester, withBuilders: false);

      for (final location in [
        AppRoutes.events,
        AppRoutes.eventGroupOf('upcoming'),
        AppRoutes.eventCreate,
      ]) {
        router.go(location);
        await tester.pumpAndSettle();

        expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      }
    });

    testWidgets('falls back to NotYetAvailable without a detail builder', (
      tester,
    ) async {
      // The other builders are supplied, so only the detail is missing.
      final router = await pumpRouter(tester, withDetailBuilder: false);

      router.go(AppRoutes.eventDetailOf('e-1'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byKey(_detailKey('e-1')), findsNothing);
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
