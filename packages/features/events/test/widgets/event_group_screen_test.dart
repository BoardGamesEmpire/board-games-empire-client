import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

class _MockEventRepository extends Mock implements EventRepository {}

/// One group's page (#497): every event in the group, in one lazily built
/// list over the cache, under the same banner as the overview.
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

  Future<void> pumpGroup(
    WidgetTester tester,
    EventGroup group, {
    Future<void> Function()? onRetry,
    void Function(BuildContext context)? onCreate,
    void Function(BuildContext context, String eventId)? onOpen,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        home: EventGroupScreen(
          group: group,
          repository: repository,
          hydration: status.watch(),
          onRetry: onRetry,
          onCreate: onCreate,
          onOpen: onOpen,
          now: () => now,
        ),
      ),
    );
    status.finished(EventHydrateOutcome.complete);
  }

  /// [count] past events, `e-past-0` the most recent.
  List<EventListItem> past(int count) => [
    for (var n = 0; n < count; n++)
      item(
        'e-past-$n',
        occurrences: [confirmed('o', DateTime.utc(2026, 10, 20 - n, 19))],
      ),
  ];

  testWidgets('is titled with its group', (tester) async {
    await pumpGroup(tester, EventGroup.planning);
    items.add(const []);
    await tester.pump();

    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Planning')),
      findsOneWidget,
    );
  });

  testWidgets("the archived page is titled and lists only the group's "
      'events, a cancelled-then-archived one marked Cancelled', (tester) async {
    // The archive keeps the event's cancelledAt, so its row says it was
    // cancelled, as its detail does, and doesn't read as one that took place.
    await pumpGroup(tester, EventGroup.archived);
    items.add([
      EventListItem(
        event: item('e-arch').event.copyWith(
          status: EventStatus.archived,
          cancelledAt: DateTime.utc(2026, 10),
        ),
        occurrences: const [],
      ),
      item('e-plan'),
    ]);
    await tester.pump();

    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Archived')),
      findsOneWidget,
    );
    expect(find.byKey(EventOverviewScreen.rowKey('e-arch')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(EventOverviewScreen.rowKey('e-arch')),
        matching: find.textContaining('Cancelled'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(EventOverviewScreen.rowKey('e-plan')), findsNothing);
  });

  testWidgets('lists every row of its group', (tester) async {
    // No cap: the overview shows five, and this page the rest.
    await pumpGroup(tester, EventGroup.past);
    items.add([...past(12), item('e-plan')]);
    await tester.pump();

    // Built lazily, so each row is reached by scrolling to it.
    for (var n = 0; n < 12; n++) {
      final row = find.byKey(EventOverviewScreen.rowKey('e-past-$n'));
      await tester.scrollUntilVisible(row, 100);
      expect(row, findsOneWidget, reason: 'e-past-$n');
    }
    expect(
      find.byKey(EventOverviewScreen.rowKey('e-plan'), skipOffstage: false),
      findsNothing,
    );
    final scrollable = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollable.semanticChildCount, 12);
  });

  testWidgets("keeps the group's order", (tester) async {
    await pumpGroup(tester, EventGroup.past);
    items.add(past(3).reversed.toList());
    await tester.pump();

    final tops = [
      for (var n = 0; n < 3; n++)
        tester
            .getTopLeft(find.byKey(EventOverviewScreen.rowKey('e-past-$n')))
            .dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets('separates its rows, but not after the last', (tester) async {
    await pumpGroup(tester, EventGroup.past);
    items.add(past(3));
    await tester.pump();

    Finder dividerIn(String id) => find.descendant(
      of: find.byKey(EventOverviewScreen.rowKey(id)),
      matching: find.byType(Divider),
    );
    expect(dividerIn('e-past-0'), findsOneWidget);
    expect(dividerIn('e-past-1'), findsOneWidget);
    expect(dividerIn('e-past-2'), findsNothing);
  });

  testWidgets("shows the group's empty copy when it empties", (tester) async {
    // The last upcoming event ends, or the user leaves it, while its page is
    // open: the page stays, and says the group is empty now.
    await pumpGroup(tester, EventGroup.past);
    items.add(past(1));
    await tester.pump();
    expect(find.byKey(EventGroupScreen.emptyKey), findsNothing);

    items.add([item('e-plan')]);
    await tester.pump();

    expect(find.byKey(EventGroupScreen.emptyKey), findsOneWidget);
    expect(find.text('Nothing here right now.'), findsOneWidget);
  });

  testWidgets('the empty state is announced', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpGroup(tester, EventGroup.past);
    items.add(const []);
    await tester.pump();

    final empty = tester.getSemantics(find.text('Nothing here right now.'));
    expect(empty, isSemantics(isLiveRegion: true));
    expect(empty.label, contains('Nothing here right now.'));
    handle.dispose();
  });

  testWidgets('shows the refresh banner over its rows', (tester) async {
    await pumpGroup(tester, EventGroup.past, onRetry: () async {});
    status.finished(EventHydrateOutcome.failed);
    items.add(past(1));
    await tester.pump();

    expect(find.byKey(EventOverviewScreen.refreshBannerKey), findsOneWidget);
    expect(find.byKey(EventOverviewScreen.refreshRetryKey), findsOneWidget);
    expect(find.byKey(EventOverviewScreen.rowKey('e-past-0')), findsOneWidget);
  });

  testWidgets('shows loading until the cache answers', (tester) async {
    await pumpGroup(tester, EventGroup.upcoming);
    await tester.pump();

    expect(find.byKey(EventOverviewScreen.loadingKey), findsOneWidget);
  });

  group('the create button', () {
    testWidgets('is absent without onCreate', (tester) async {
      await pumpGroup(tester, EventGroup.past);
      items.add(past(1));
      await tester.pump();

      expect(find.byKey(EventGroupScreen.createKey), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('calls onCreate with it', (tester) async {
      var created = 0;
      await pumpGroup(tester, EventGroup.past, onCreate: (_) => created++);
      items.add(past(1));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(EventGroupScreen.createKey),
          matching: find.text('New event'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(EventGroupScreen.createKey));

      expect(created, 1);
    });

    testWidgets('stays on a group that has emptied', (tester) async {
      // The page stays when its group empties, and so does the way to make
      // the next event.
      await pumpGroup(tester, EventGroup.past, onCreate: (_) {});
      items.add(const []);
      await tester.pump();

      expect(find.byKey(EventGroupScreen.emptyKey), findsOneWidget);
      expect(find.byKey(EventGroupScreen.createKey), findsOneWidget);
    });

    testWidgets('leaves the last row room to scroll clear of it', (
      tester,
    ) async {
      await pumpGroup(tester, EventGroup.past, onCreate: (_) {});
      items.add(past(12));
      await tester.pump();

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
      await tester.pumpAndSettle();

      final last = find.byKey(EventOverviewScreen.rowKey('e-past-11'));
      final button = find.byKey(EventGroupScreen.createKey);
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(tester.getRect(button).top),
      );
    });
  });

  group('accessibility audit', () {
    // The screen is pumped by `pumpGroup`, which wants the tester, so each
    // call pumps it with `pump`, and its arrange feeds the screen's reads.

    /// The [group]'s screen, with rows that open, as the shell's do, so they
    /// are audited as the tap targets they are rather than as inert text.
    Future<void> Function(WidgetTester, ThemeData) showing(EventGroup group) =>
        (tester, theme) => pumpGroup(
          tester,
          group,
          onRetry: () async {},
          onCreate: (_) {},
          onOpen: (_, _) {},
          theme: theme,
        );

    /// The hydrate ends with [outcome], and the cache answers [rows], or
    /// fails with [error].
    Future<void> feed(
      WidgetTester tester,
      List<EventListItem>? rows, {
      Object? error,
      EventHydrateOutcome outcome = EventHydrateOutcome.complete,
    }) async {
      status.finished(outcome);
      if (error != null) items.addError(error);
      if (rows != null) items.add(rows);
      await tester.pump();
    }

    // Nothing has answered: the spinner never settles.
    auditScreen(
      'loading',
      pump: (tester, theme) async {
        await pumpGroup(
          tester,
          EventGroup.upcoming,
          onCreate: (_) {},
          theme: theme,
        );
        await tester.pump();
        expect(find.byKey(EventOverviewScreen.loadingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready',
      pump: showing(EventGroup.past),
      arrange: (tester) async {
        await feed(tester, past(12));
        await tester.pumpAndSettle();
        expect(find.byKey(EventOverviewScreen.rowKey('e-past-0')), findsOne);
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      pump: showing(EventGroup.past),
      arrange: (tester) async {
        await feed(tester, past(12));
        await scrollListToEnd(
          tester,
          find.byKey(EventOverviewScreen.rowKey('e-past-11')),
        );
      },
    );

    auditScreen(
      'empty',
      pump: showing(EventGroup.past),
      arrange: (tester) async {
        await feed(tester, const []);
        await tester.pumpAndSettle();
        expect(find.byKey(EventGroupScreen.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      pump: showing(EventGroup.past),
      arrange: (tester) async {
        await feed(tester, null, error: StateError('x'));
        await tester.pumpAndSettle();
        expect(find.byKey(EventOverviewScreen.errorKey), findsOneWidget);
      },
    );

    auditScreen(
      'refresh failed',
      pump: showing(EventGroup.past),
      arrange: (tester) async {
        await feed(tester, past(3), outcome: EventHydrateOutcome.failed);
        await tester.pumpAndSettle();
        expect(
          find.byKey(EventOverviewScreen.refreshBannerKey),
          findsOneWidget,
        );
      },
    );
  });
}
