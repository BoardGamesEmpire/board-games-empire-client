import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _emptyTitleCopy = 'No events yet';
const _emptyBodyCopy = "Events you're hosting or invited to show up here.";
const _refreshFailedCopy =
    "Couldn't refresh your events. What's shown may be out of date.";
const _errorCopy = "Your events couldn't be read.";
const _retryCopy = 'Try again';

/// Pins the #497 overview against a mocked repository and a hand-driven
/// hydration stream: its groups and their cap, the see-all, the surfaces
/// around them, and the hooks it offers #498 and #499.
void main() {
  final now = DateTime.utc(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<List<EventListItem>> items;
  late EventHydrationStatus status;

  setUp(() {
    repository = _MockEventRepository();
    items = StreamController<List<EventListItem>>.broadcast();
    status = EventHydrationStatus();
    when(repository.watchAttendingEventListItems)
        .thenAnswer((_) => items.stream);
  });

  tearDown(() {
    unawaited(items.close());
    unawaited(status.close());
  });

  Widget app(Widget home, {TextScaler textScaler = TextScaler.noScaling}) =>
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: home,
      );

  Widget harness({
    void Function(BuildContext context, String eventId)? onOpen,
    void Function(BuildContext context, EventGroup group)? onOpenGroup,
    void Function(BuildContext context)? onCreate,
    Future<void> Function()? onRetry,
    VoidCallback? onEnter,
    Stream<List<Household>>? households,
    TextScaler textScaler = TextScaler.noScaling,
  }) => app(
    EventOverviewScreen(
      repository: repository,
      households: households,
      hydration: status.watch(),
      onOpen: onOpen,
      onOpenGroup: onOpenGroup,
      onCreate: onCreate,
      onRetry: onRetry,
      onEnter: onEnter,
      now: () => now,
    ),
    textScaler: textScaler,
  );

  /// Shows [rows] with the hydrate settled.
  Future<void> show(
    WidgetTester tester,
    List<EventListItem> rows, {
    void Function(BuildContext context, EventGroup group)? onOpenGroup,
    void Function(BuildContext context)? onCreate,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(
      harness(
        onOpenGroup: onOpenGroup,
        onCreate: onCreate,
        textScaler: textScaler,
      ),
    );
    status.finished(EventHydrateOutcome.complete);
    items.add(rows);
    await tester.pump();
  }

  DateTime day(int day) => DateTime.utc(2026, 10, day, 19);

  /// [count] upcoming events, `e-up-0` soonest.
  List<EventListItem> upcoming(int count) => [
    for (var n = 0; n < count; n++)
      item('e-up-$n', occurrences: [confirmed('o', day(24 + n))]),
  ];

  testWidgets('shows loading, then the groups in order', (tester) async {
    await tester.pumpWidget(harness());
    status.started();
    await tester.pump();
    expect(find.byKey(EventOverviewScreen.loadingKey), findsOneWidget);

    items.add([
      item('e-past', occurrences: [confirmed('o', day(20))]),
      item('e-plan'),
      item('e-up', occurrences: [confirmed('o', day(25))]),
    ]);
    await tester.pump();

    expect(find.byKey(EventOverviewScreen.loadingKey), findsNothing);
    for (final group in EventGroup.values) {
      expect(find.byKey(EventOverviewScreen.groupKey(group)), findsOneWidget);
    }
    // The groups are slivers, so their headings are what is measured.
    final tops = [
      for (final heading in ['Upcoming', 'Planning', 'Past'])
        tester.getTopLeft(find.text(heading)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(tops.toSet(), hasLength(3));
  });

  testWidgets('announces each group name as a heading', (tester) async {
    await show(tester, upcoming(1));

    expect(
      tester.getSemantics(find.text('Upcoming')),
      isSemantics(isHeader: true),
    );
  });

  group('a group', () {
    testWidgets('shows at most five rows', (tester) async {
      await show(tester, upcoming(7), onOpenGroup: (_, _) {});

      for (var n = 0; n < 5; n++) {
        expect(
          find.byKey(EventOverviewScreen.rowKey('e-up-$n')),
          findsOneWidget,
        );
      }
      expect(find.byKey(EventOverviewScreen.rowKey('e-up-5')), findsNothing);
      expect(
        find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
        findsOneWidget,
      );
      expect(EventOverviewScreen.groupCap, 5);
    });

    testWidgets('see all says how many, and calls onOpenGroup with the '
        'group', (tester) async {
      final opened = <EventGroup>[];
      await show(tester, upcoming(7), onOpenGroup: (_, g) => opened.add(g));

      expect(find.text('See all (7)'), findsOneWidget);
      expect(
        tester.getSemantics(
          find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
        ),
        isSemantics(label: 'Upcoming: see all 7 events', isButton: true),
      );

      await tester.tap(
        find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
      );

      expect(opened, [EventGroup.upcoming]);
    });

    testWidgets('of five or fewer has no see all', (tester) async {
      // Every event in it is already shown, so the button would lead
      // nowhere new.
      await show(tester, upcoming(5), onOpenGroup: (_, _) {});

      expect(
        find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
        findsNothing,
      );
    });

    testWidgets('has no see all without onOpenGroup', (tester) async {
      await show(tester, upcoming(7));

      expect(
        find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
        findsNothing,
      );
    });

    testWidgets('with no events is left off', (tester) async {
      await show(tester, upcoming(2));

      expect(
        find.byKey(EventOverviewScreen.groupKey(EventGroup.upcoming)),
        findsOneWidget,
      );
      expect(
        find.byKey(EventOverviewScreen.groupKey(EventGroup.planning)),
        findsNothing,
      );
      expect(
        find.byKey(EventOverviewScreen.groupKey(EventGroup.past)),
        findsNothing,
      );
    });
  });

  testWidgets('tells a screen reader how many rows there are', (tester) async {
    // Rows are numbered across the groups on screen, so "item 6 of 6" is
    // the last row shown, not the last of its group (#210).
    await show(tester, [...upcoming(7), item('e-plan')]);

    final scrollable = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollable.semanticChildCount, 6);
  });

  testWidgets('no events shows the empty state', (tester) async {
    await show(tester, const []);

    expect(find.byKey(EventOverviewScreen.emptyKey), findsOneWidget);
    expect(find.text(_emptyTitleCopy), findsOneWidget);
  });

  group('the empty state', () {
    testWidgets('offers New event when onCreate is given, and calls it', (
      tester,
    ) async {
      var created = 0;
      await show(tester, const [], onCreate: (_) => created++);

      final button = find.descendant(
        of: find.byKey(EventOverviewScreen.emptyKey),
        matching: find.byKey(EventOverviewScreen.emptyCreateKey),
      );
      expect(button, findsOneWidget);
      expect(
        find.descendant(of: button, matching: find.text('New event')),
        findsOneWidget,
      );
      // Under the body, which says where events come from.
      expect(
        tester.getTopLeft(button).dy,
        greaterThan(tester.getBottomLeft(find.text(_emptyBodyCopy)).dy),
      );

      await tester.tap(button);

      expect(created, 1);
    });

    testWidgets('offers nothing without onCreate', (tester) async {
      await show(tester, const []);

      expect(find.byKey(EventOverviewScreen.emptyKey), findsOneWidget);
      expect(find.byKey(EventOverviewScreen.emptyCreateKey), findsNothing);
      expect(find.byType(ButtonStyleButton), findsNothing);
    });

    testWidgets('keeps its button in the window at 200% text, 320dp wide', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 800));
      await show(
        tester,
        const [],
        onCreate: (_) {},
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );

      expect(tester.takeException(), isNull);
      final rect = tester.getRect(
        find.byKey(EventOverviewScreen.emptyCreateKey),
      );
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    });
  });

  group('a failed read', () {
    testWidgets('offers a retry that runs a pass', (tester) async {
      var calls = 0;
      await tester.pumpWidget(harness(onRetry: () async => calls++));
      items.addError(StateError('no authenticated user'));
      await tester.pump();

      expect(find.byKey(EventOverviewScreen.errorKey), findsOneWidget);
      expect(find.text(_errorCopy), findsOneWidget);

      await tester.tap(find.text(_retryCopy));
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('says the retry is running, and offers it again after', (
      tester,
    ) async {
      // A press that leaves the failure up would otherwise look like one
      // that did nothing.
      final pass = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        harness(
          onRetry: () {
            calls++;
            return pass.future;
          },
        ),
      );
      items.addError(StateError('no authenticated user'));
      await tester.pump();

      await tester.tap(find.text(_retryCopy));
      await tester.pump();

      expect(find.byKey(EventOverviewScreen.errorKey), findsOneWidget);
      expect(find.text('Refreshing…'), findsOneWidget);
      expect(find.text(_retryCopy), findsNothing);
      await tester.tap(find.text('Refreshing…'), warnIfMissed: false);
      expect(calls, 1, reason: 'disabled while the pass runs');

      pass.complete();
      await tester.pump();

      expect(find.byKey(EventOverviewScreen.errorKey), findsOneWidget);
      expect(find.text(_retryCopy), findsOneWidget);
    });

    testWidgets('says so with nothing to press where no retry exists', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      items.addError(StateError('no authenticated user'));
      await tester.pump();

      expect(find.byKey(EventOverviewScreen.errorKey), findsOneWidget);
      expect(find.text(_errorCopy), findsOneWidget);
      expect(find.byType(ButtonStyleButton), findsNothing);
    });
  });

  group('the refresh banner', () {
    testWidgets('offers retry only when onRetry is set', (tester) async {
      await tester.pumpWidget(harness());
      items.add(upcoming(1));
      status.finished(EventHydrateOutcome.failed);
      await tester.pump();

      expect(find.byKey(EventOverviewScreen.refreshBannerKey), findsOneWidget);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(EventOverviewScreen.refreshRetryKey), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(harness(onRetry: () async {}));
      items.add(upcoming(1));
      await tester.pump();

      expect(find.byKey(EventOverviewScreen.refreshRetryKey), findsOneWidget);
    });

    testWidgets('pressing retry runs a pass and says so', (tester) async {
      final pass = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        harness(
          onRetry: () {
            calls++;
            return pass.future;
          },
        ),
      );
      items.add(upcoming(1));
      status.finished(EventHydrateOutcome.failed);
      await tester.pump();

      await tester.tap(find.byKey(EventOverviewScreen.refreshRetryKey));
      await tester.pump();

      expect(calls, 1);
      expect(find.text('Refreshing…'), findsNWidgets(2));

      pass.complete();
      status.finished(EventHydrateOutcome.complete);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(EventOverviewScreen.refreshBannerKey), findsNothing);
    });
  });

  group('the create button', () {
    testWidgets('is absent without onCreate', (tester) async {
      await show(tester, upcoming(1));

      expect(find.byKey(EventOverviewScreen.createKey), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('calls onCreate with it', (tester) async {
      var created = 0;
      await tester.pumpWidget(harness(onCreate: (_) => created++));
      items.add(const []);
      await tester.pump();

      await tester.tap(find.byKey(EventOverviewScreen.createKey));

      // Scoped to the button: the empty state this list shows has a New
      // event button too.
      expect(
        find.descendant(
          of: find.byKey(EventOverviewScreen.createKey),
          matching: find.text('New event'),
        ),
        findsOneWidget,
      );
      expect(created, 1);
    });

    testWidgets('leaves the last row room to scroll clear of it', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 400));
      await show(tester, upcoming(4), onCreate: (_) {});

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
      await tester.pumpAndSettle();

      final last = find.byKey(EventOverviewScreen.rowKey('e-up-3'));
      final button = find.byKey(EventOverviewScreen.createKey);
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(tester.getRect(button).top),
      );
    });
  });

  group('the entry trigger', () {
    testWidgets('fires once per entry', (tester) async {
      // `BlocProvider.create` runs once per insertion, which is what "on
      // entry" means; a route builder runs on every router rebuild.
      var entries = 0;
      await tester.pumpWidget(harness(onEnter: () => entries++));
      items.add(upcoming(1));
      await tester.pump();
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      expect(entries, 1);
    });
  });

  testWidgets('rows are inert without onOpen', (tester) async {
    await show(tester, upcoming(1));

    expect(
      tester.getSemantics(find.byKey(EventOverviewScreen.rowKey('e-up-0'))),
      isSemantics(isButton: false, hasTapAction: false, isFocusable: false),
    );
  });

  testWidgets('a row calls onOpen with its event', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(harness(onOpen: (_, id) => opened.add(id)));
    items.add(upcoming(2));
    await tester.pump();

    await tester.tap(find.byKey(EventOverviewScreen.rowKey('e-up-1')));

    expect(opened, ['e-up-1']);
  });

  testWidgets('lays out at 200% text on a narrow window', (tester) async {
    useViewSize(tester, const Size(320, 800));
    await tester.pumpWidget(
      harness(
        onOpenGroup: (_, _) {},
        onCreate: (_) {},
        households: Stream.value([
          Household(
            id: 'h-1',
            name: 'The Smiths of Little Whinging',
            createdAt: now,
            updatedAt: now,
          ),
        ]),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      ),
    );
    status.finished(EventHydrateOutcome.failed);
    items.add([
      // The soonest, so it is among the five the overview shows, and in
      // another year, so its date line is the longer form. Every part of its
      // detail line is present.
      item(
        'e-long',
        title: 'A' * 60,
        householdId: 'h-1',
        location: 'The back room of the board game café',
        attendance: attendance(EventParticipationStatus.notAttending),
        // Local, so the day it shows doesn't depend on the test machine's
        // zone.
        occurrences: [confirmed('o', DateTime(2027, 12, 29, 19))],
      ),
      for (var n = 0; n < 6; n++)
        item(
          'e-later-$n',
          occurrences: [confirmed('o', DateTime.utc(2028, 1, 1 + n, 19))],
        ),
    ]);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(EventOverviewScreen.rowKey('e-long')), findsOneWidget);
    expect(find.textContaining('Wed, Dec 29, 2027'), findsOneWidget);
    expect(
      find.text(
        'The back room of the board game café · '
        'The Smiths of Little Whinging · Not going',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
      findsOneWidget,
    );
  });

  testWidgets('the overview body can be hosted without the page', (
    tester,
  ) async {
    // Another host may put the overview beside something else, under its own
    // app bar, so the body cannot bring one.
    await tester.pumpWidget(
      app(
        Scaffold(
          body: BlocProvider(
            create: (_) => EventOverviewBloc(
              repository: repository,
              hydration: status.watch(),
              now: () => now,
            ),
            child: CustomScrollView(
              slivers: [EventOverviewSliver(now: () => now)],
            ),
          ),
        ),
      ),
    );
    status.finished(EventHydrateOutcome.complete);
    items.add(upcoming(1));
    await tester.pump();

    expect(find.byKey(EventOverviewScreen.rowKey('e-up-0')), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(BgePage), findsNothing);
  });
}
