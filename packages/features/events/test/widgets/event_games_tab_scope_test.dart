import 'package:bloc_test/bloc_test.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

class _MockGames extends MockBloc<EventGamesEvent, EventGamesState>
    implements EventGamesBloc {}

class _MockNominations
    extends MockBloc<EventNominationsEvent, EventNominationsState>
    implements EventNominationsBloc {}

class _MockDetail extends MockBloc<EventDetailEvent, EventDetailState>
    implements EventDetailBloc {}

/// The scope under the screen's tab controller and the blocs it reads, with
/// the controller it holds handed to [onBuild] on each build.
Widget _harness({
  required void Function(EventGamesTabController controller) onBuild,
  EventGamesSection initialSection = EventGamesSection.nominations,
  bool disableAnimations = false,
}) {
  final games = _MockGames();
  final nominations = _MockNominations();
  final detail = _MockDetail();
  whenListen(
    games,
    const Stream<EventGamesState>.empty(),
    initialState: const EventGamesState(),
  );
  whenListen(
    nominations,
    const Stream<EventNominationsState>.empty(),
    initialState: const EventNominationsState(),
  );
  whenListen(
    detail,
    const Stream<EventDetailState>.empty(),
    initialState: const EventDetailLoading(),
  );
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: MultiBlocProvider(
      providers: [
        BlocProvider<EventGamesBloc>.value(value: games),
        BlocProvider<EventNominationsBloc>.value(value: nominations),
        BlocProvider<EventDetailBloc>.value(value: detail),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultTabController(
          length: EventDetailTab.values.length,
          child: EventGamesTabScope(
            onFirstShown: (_, _) => false,
            initialSection: initialSection,
            child: Builder(
              builder: (context) {
                onBuild(EventGamesTabScope.of(context));
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    ),
  );
}

/// What the Games tab keeps across the screen's rebuilds (#516), and how its
/// filter takes each change (#851).
void main() {
  test("the filter sheet's facets leave the search field's query as it "
      'was', () {
    final controller = EventGamesTabController();
    addTearDown(controller.dispose);

    controller
      ..setQuery('catan')
      ..setGameFilter(
        const CollectionFilter(
          query: 'root',
          mediums: {GameMedium.digital},
        ),
      );

    expect(controller.filter.query, 'catan');
    expect(controller.filter.game.mediums, {GameMedium.digital});
  });

  group('the sub-tabs', () {
    testWidgets('open on initialSection', (tester) async {
      late EventGamesTabController controller;
      await tester.pumpWidget(
        _harness(
          initialSection: EventGamesSection.pool,
          onBuild: (c) => controller = c,
        ),
      );

      expect(controller.section, EventGamesSection.pool);
    });

    testWidgets('a sub-tab change notifies once, as it starts, not again '
        'when it settles', (tester) async {
      late EventGamesTabController controller;
      await tester.pumpWidget(_harness(onBuild: (c) => controller = c));
      var notified = 0;
      controller.addListener(() => notified++);

      controller.sections.animateTo(
        EventGamesSection.pool.index,
        duration: const Duration(milliseconds: 300),
      );
      await tester.pump();

      expect(controller.sections.indexIsChanging, isTrue);
      expect(notified, 1);

      await tester.pumpAndSettle();

      expect(controller.sections.indexIsChanging, isFalse);
      expect(controller.section, EventGamesSection.pool);
      expect(notified, 1);
    });

    testWidgets('reduced motion moves the indicator at once and keeps the '
        'sub-tab', (tester) async {
      late EventGamesTabController controller;
      await tester.pumpWidget(
        _harness(
          initialSection: EventGamesSection.pool,
          onBuild: (c) => controller = c,
        ),
      );
      final before = controller.sections;
      expect(before.animationDuration, isNot(Duration.zero));
      var notified = 0;
      controller.addListener(() => notified++);

      await tester.pumpWidget(
        _harness(
          initialSection: EventGamesSection.pool,
          disableAnimations: true,
          onBuild: (c) => controller = c,
        ),
      );
      await tester.pump();

      expect(controller.section, EventGamesSection.pool);
      expect(controller.sections, isNot(same(before)));
      expect(controller.sections.animationDuration, Duration.zero);
      expect(controller.sections.index, EventGamesSection.pool.index);
      // The swap tells the page once, so it builds on the new controller; it
      // is not a change of sub-tab, so nothing more.
      expect(notified, 1);

      controller.sections.animateTo(0);
      await tester.pumpAndSettle();

      expect(controller.section, EventGamesSection.lineup);
      expect(notified, 2);
    });
  });
}
