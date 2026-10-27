import 'dart:async';

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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        home: EventGroupScreen(
          group: group,
          repository: repository,
          hydration: status.watch(),
          onRetry: onRetry,
          onCreate: onCreate,
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
}
