import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

/// One event's row on the overview (#497): its date line in device-local
/// time, with the platform's 24-hour setting and the year only when it isn't
/// this year, and its detail line.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  Future<void> pumpRow(
    WidgetTester tester,
    EventRow row, {
    bool alwaysUse24HourFormat = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: BgeTheme.light(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: EventsLocalizations.localizationsDelegates,
      supportedLocales: EventsLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(alwaysUse24HourFormat: alwaysUse24HourFormat),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          children: [
            EventRowTile(
              key: EventOverviewScreen.rowKey(row.event.id),
              row: row,
              now: () => now,
            ),
          ],
        ),
      ),
    ),
  );

  EventRow dated(DateTime start, {EventParticipationStatus? rsvp}) => EventRow(
    event: item('e-1', title: 'Game night').event,
    group: EventGroup.upcoming,
    date: confirmed('o-1', start),
    rsvp: rsvp,
  );

  EventRow undated({required bool beingChosen}) => EventRow(
    event: item('e-1').event,
    group: EventGroup.planning,
    dateBeingChosen: beingChosen,
  );

  String semanticsLabel(WidgetTester tester) =>
      tester.getSemantics(find.byKey(EventOverviewScreen.rowKey('e-1'))).label;

  group('the time follows the 24-hour setting', () {
    // An en_US device is 12-hour by default. A user who switched it to 24-hour
    // must see 19:30, which intl's locale patterns alone would not give them.
    final start = DateTime(2026, 11, 6, 19, 30);

    testWidgets('on', (tester) async {
      await pumpRow(tester, dated(start), alwaysUse24HourFormat: true);

      expect(find.textContaining('19:30'), findsOneWidget);
      expect(find.textContaining('PM'), findsNothing);
    });

    testWidgets('off', (tester) async {
      await pumpRow(tester, dated(start));

      expect(find.textContaining('7:30 PM'), findsOneWidget);
    });
  });

  group('a date', () {
    testWidgets('this year leaves the year out', (tester) async {
      await pumpRow(tester, dated(DateTime(2026, 11, 6, 19, 30)));

      expect(find.textContaining('Fri, Nov 6'), findsOneWidget);
      expect(find.textContaining('2026'), findsNothing);
    });

    testWidgets('in another year shows the year', (tester) async {
      await pumpRow(tester, dated(DateTime(2027, 1, 8, 19, 30)));

      expect(find.textContaining('Fri, Jan 8, 2027'), findsOneWidget);
    });

    testWidgets('stored in UTC shows in local time', (tester) async {
      // The server sends instants in UTC; the user goes on their own day.
      final local = DateTime(2026, 11, 6, 19, 30);
      await pumpRow(tester, dated(local.toUtc()));

      expect(find.textContaining('7:30 PM'), findsOneWidget);
    });
  });

  testWidgets('planning rows read date being chosen or no date yet', (
    tester,
  ) async {
    await pumpRow(tester, undated(beingChosen: true));
    expect(find.text('Date being chosen'), findsOneWidget);

    await pumpRow(tester, undated(beingChosen: false));
    expect(find.text('No date yet'), findsOneWidget);
  });

  group('the detail line', () {
    testWidgets('joins venue, household and rsvp', (tester) async {
      await pumpRow(
        tester,
        EventRow(
          event: item('e-1').event,
          group: EventGroup.planning,
          venue: 'Back room',
          householdName: 'The Smiths',
          rsvp: EventParticipationStatus.attending,
        ),
      );

      expect(find.text('Back room · The Smiths · Going'), findsOneWidget);
      // A screen reader would read the visual separator's symbol out.
      expect(semanticsLabel(tester), contains('Back room, The Smiths, Going'));
    });

    testWidgets('shows only the parts there are', (tester) async {
      await pumpRow(
        tester,
        EventRow(
          event: item('e-1').event,
          group: EventGroup.planning,
          householdName: 'The Smiths',
        ),
      );

      expect(find.text('The Smiths'), findsOneWidget);
    });

    testWidgets('is left off when there is nothing to show', (tester) async {
      await pumpRow(tester, undated(beingChosen: false));

      // The title and the date line, and nothing under them.
      expect(
        find.descendant(of: find.byType(ListTile), matching: find.byType(Text)),
        findsNWidgets(2),
      );
    });

    testWidgets('an unknown rsvp shows nothing', (tester) async {
      // A value a newer server adds. Not a guess at what it means.
      await pumpRow(
        tester,
        dated(DateTime(2026, 11, 6), rsvp: EventParticipationStatus.unknown),
      );

      expect(
        find.descendant(of: find.byType(ListTile), matching: find.byType(Text)),
        findsNWidgets(2),
      );
    });

    testWidgets('names each rsvp', (tester) async {
      const labels = {
        EventParticipationStatus.attending: 'Going',
        EventParticipationStatus.maybe: 'Maybe',
        EventParticipationStatus.notAttending: 'Not going',
        EventParticipationStatus.invited: 'Invited',
      };
      for (final MapEntry(key: rsvp, value: label) in labels.entries) {
        await pumpRow(
          tester,
          EventRow(
            event: item('e-1').event,
            group: EventGroup.planning,
            rsvp: rsvp,
          ),
        );

        expect(find.text(label), findsOneWidget, reason: '$rsvp');
      }
    });

    testWidgets('declined reads not going', (tester) async {
      // Declined events stay on the list, labelled once the answer is known.
      await pumpRow(
        tester,
        dated(
          DateTime(2026, 11, 6),
          rsvp: EventParticipationStatus.notAttending,
        ),
      );

      expect(find.text('Not going'), findsOneWidget);
    });
  });

  testWidgets('is one node for a screen reader', (tester) async {
    await pumpRow(
      tester,
      EventRow(
        event: item('e-1', title: 'Catan night').event,
        group: EventGroup.upcoming,
        date: confirmed('o-1', DateTime(2026, 11, 6, 19, 30)),
        venue: 'Back room',
      ),
    );

    final label = semanticsLabel(tester);
    for (final part in ['Catan night', 'Fri, Nov 6', '7:30 PM', 'Back room']) {
      expect(label, contains(part));
    }
  });

  testWidgets('is inert without onOpen, and opens with it', (tester) async {
    // A tap that leads nowhere is worse than no tap (#269).
    await pumpRow(tester, undated(beingChosen: false));
    expect(
      tester.getSemantics(find.byKey(EventOverviewScreen.rowKey('e-1'))),
      isSemantics(isButton: false, hasTapAction: false, isFocusable: false),
    );

    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        home: Scaffold(
          body: EventRowTile(
            key: EventOverviewScreen.rowKey('e-1'),
            row: undated(beingChosen: false),
            now: () => now,
            onOpen: (_, id) => opened.add(id),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(EventOverviewScreen.rowKey('e-1')));

    expect(opened, ['e-1']);
  });
}
