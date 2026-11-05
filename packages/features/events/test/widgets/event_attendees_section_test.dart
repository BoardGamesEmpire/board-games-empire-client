import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_detail_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

EventAttendee _who(
  String id,
  String name,
  EventParticipationStatus status, {
  EventRole role = EventRole.participant,
  String? notes,
}) => EventAttendee(
  id: id,
  eventId: 'e-1',
  guestName: name,
  role: role,
  status: status,
  notes: notes,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// Who's coming (#508): the roster grouped by answer, with counts and notes.
void main() {
  Future<void> pump(
    WidgetTester tester,
    List<EventAttendee>? attendees, {
    Size? size,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        locale: const Locale('en', 'US'),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: EventAttendeesSection(attendees: attendees),
          ),
        ),
      ),
    );
  }

  const going = EventParticipationStatus.attending;
  const maybe = EventParticipationStatus.maybe;
  const invited = EventParticipationStatus.invited;
  const notGoing = EventParticipationStatus.notAttending;
  const unknown = EventParticipationStatus.unknown;

  testWidgets(
    'groups the roster as Going, Maybe, Not answered, Not going, with counts',
    (tester) async {
      await pump(tester, [
        _who('1', 'Ann', notGoing),
        _who('2', 'Bob', going),
        _who('3', 'Cy', invited),
        _who('4', 'Di', going),
        _who('5', 'Ed', maybe),
      ]);

      final headings = [
        'Going (2)',
        'Maybe (1)',
        'Not answered (1)',
        'Not going (1)',
      ];
      final tops = [
        for (final heading in headings)
          tester.getTopLeft(find.text(heading)).dy,
      ];
      expect([...tops]..sort(), tops);

      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Going (2)'), lessThan(top('Bob')));
      expect(top('Bob'), lessThan(top('Di')));
      expect(top('Di'), lessThan(top('Maybe (1)')));
      expect(top('Maybe (1)'), lessThan(top('Ed')));
      expect(top('Ed'), lessThan(top('Not answered (1)')));
      expect(top('Not answered (1)'), lessThan(top('Cy')));
      expect(top('Cy'), lessThan(top('Not going (1)')));
      expect(top('Not going (1)'), lessThan(top('Ann')));
      expect(
        find.byKey(EventDetailScreen.attendeeGroupKey(going)),
        findsOneWidget,
      );
    },
  );

  testWidgets('leaves out a group with nobody in it', (tester) async {
    await pump(tester, [_who('1', 'Ann', going)]);

    expect(find.text('Going (1)'), findsOneWidget);
    expect(find.textContaining('Maybe'), findsNothing);
    expect(find.textContaining('Not answered'), findsNothing);
    expect(find.textContaining('Not going'), findsNothing);
    expect(find.textContaining('Other answers'), findsNothing);
    expect(find.byKey(EventDetailScreen.attendeeGroupKey(maybe)), findsNothing);
  });

  testWidgets('an unknown status goes last, under Other answers, with no '
      'answer word on the row', (tester) async {
    await pump(tester, [_who('1', 'Zed', unknown), _who('2', 'Ann', notGoing)]);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('Not going (1)'), lessThan(top('Other answers (1)')));
    expect(top('Other answers (1)'), lessThan(top('Zed')));
    expect(find.text('Participant'), findsOneWidget);
    expect(
      find.byKey(EventDetailScreen.attendeeGroupKey(unknown)),
      findsOneWidget,
    );
  });

  testWidgets('a row shows its note under its role and answer', (tester) async {
    await pump(tester, [
      _who('1', 'Ann', going, notes: 'Bringing snacks'),
      _who('2', 'Bob', going),
    ]);

    expect(find.text('Participant · Going'), findsNWidgets(2));
    expect(find.text('Bringing snacks'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Bringing snacks')).dy,
      greaterThan(tester.getTopLeft(find.text('Participant · Going').first).dy),
    );
  });

  testWidgets('the three states stay', (tester) async {
    await pump(tester, null);
    expect(find.text('Not loaded yet.'), findsOneWidget);
    expect(find.textContaining('('), findsNothing);

    await pump(tester, const []);
    expect(
      find.text("You can't see who's coming to this event."),
      findsOneWidget,
    );
    expect(find.textContaining('('), findsNothing);
  });

  testWidgets('each heading is a semantics header', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, [
      _who('1', 'Ann', going),
      _who('2', 'Bob', maybe),
      _who('3', 'Cy', unknown),
    ]);

    for (final heading in ['Going (1)', 'Maybe (1)', 'Other answers (1)']) {
      expect(
        tester.getSemantics(find.text(heading)),
        matchesSemantics(label: heading, isHeader: true),
      );
    }
    handle.dispose();
  });

  testWidgets('fits at 320dp and 2.0 text scale', (tester) async {
    await pump(
      tester,
      [
        _who(
          '1',
          'A very long name that has to wrap across several lines here',
          notGoing,
          notes: 'A long note that also has to wrap across several lines',
        ),
        _who('2', 'Bob', unknown),
      ],
      size: const Size(320, 640),
      textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
    );

    expect(tester.takeException(), isNull);
  });
}
