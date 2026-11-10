import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_detail_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
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

const _onlineOnlyCopy = "Available when you're online";

/// Who's coming (#508): the roster grouped by answer, with counts and notes.
/// Then each row's menu (#510): someone else's answer, and Remove.
void main() {
  Future<void> pump(
    WidgetTester tester,
    List<EventAttendee>? attendees, {
    Widget? controls,
    Size? size,
    TextScaler textScaler = TextScaler.noScaling,
    AttendeeReach reach = AttendeeReach.none,
    String? viewerAttendeeId,
    bool enabled = false,
    void Function(EventAttendee row, EventParticipationStatus answer)? onAnswer,
    void Function(EventAttendee row)? onRemove,
    Widget? addButton,
    bool offline = false,
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
        builder: (context, child) => BgeConnectivityScope(
          offline: offline,
          noticeShowing: offline,
          onlineOnlyReason: _onlineOnlyCopy,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: EventAttendeesSection(
              attendees: attendees,
              controls: controls,
              reach: reach,
              viewerAttendeeId: viewerAttendeeId,
              enabled: enabled,
              onAnswer: onAnswer,
              onRemove: onRemove,
              addButton: addButton,
            ),
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

  testWidgets('a note of only spaces is no note, and one with spaces round it '
      'shows without them', (tester) async {
    await pump(tester, [
      _who('1', 'Ann', going, notes: ' \n '),
      _who('2', 'Bob', going, notes: '  Bringing snacks \n'),
    ]);

    Finder rowOf(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(MergeSemantics),
    );
    // A name and a role and answer, and nothing under them.
    expect(
      find.descendant(of: rowOf('Ann'), matching: find.byType(Text)),
      findsNWidgets(2),
    );
    expect(find.text('Bringing snacks'), findsOneWidget);
  });

  testWidgets('a row with no name, role, answer or note is left out, and no '
      'heading counts it, an empty note included', (tester) async {
    EventAttendee nobody(String id, String? notes) => EventAttendee(
      id: id,
      eventId: 'e-1',
      status: unknown,
      notes: notes,
      createdAt: kItemInstant,
      updatedAt: kItemInstant,
    );
    Finder rowsOf(EventParticipationStatus status) => find.descendant(
      of: find.byKey(EventDetailScreen.attendeeGroupKey(status)),
      matching: find.byType(MergeSemantics),
    );

    for (final notes in [null, '', ' \n ']) {
      final reason = 'notes: $notes';

      // Alone, it leaves no group: a heading over no rows would count
      // someone it doesn't show.
      await pump(tester, [_who('1', 'Ann', going), nobody('2', notes)]);
      expect(
        find.byKey(EventDetailScreen.attendeeGroupKey(unknown)),
        findsNothing,
        reason: reason,
      );
      expect(
        find.textContaining('Other answers'),
        findsNothing,
        reason: reason,
      );

      // Beside a row that shows, the count is of the rows that show.
      await pump(tester, [_who('1', 'Zed', unknown), nobody('2', notes)]);
      expect(find.text('Other answers (1)'), findsOneWidget, reason: reason);
      // A row is one merged semantics node.
      expect(rowsOf(unknown), findsOneWidget, reason: reason);
    }
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

  testWidgets('the controls sit under the heading, above the roster in each '
      'of its states', (tester) async {
    const controls = Text('The answer chips');
    double top(String text) => tester.getTopLeft(find.text(text)).dy;

    for (final (attendees, first) in [
      ([_who('1', 'Ann', going)], 'Going (1)'),
      // The viewer's answer needs only their own row, not a roster they
      // may read.
      (null, 'Not loaded yet.'),
      (const <EventAttendee>[], "You can't see who's coming to this event."),
    ]) {
      await pump(tester, attendees, controls: controls);

      expect(top("Who's coming"), lessThan(top('The answer chips')));
      expect(top('The answer chips'), lessThan(top(first)), reason: first);
    }
  });

  testWidgets('an add button sits under the controls, over the roster, at '
      'its own width, a step above the first group', (tester) async {
    // The slot #510's Add people fills.
    await pump(
      tester,
      [_who('1', 'Ann', going)],
      controls: const Text('The answer chips'),
      addButton: TextButton(onPressed: () {}, child: const Text('Add')),
    );
    double top(String text) => tester.getTopLeft(find.text(text)).dy;

    expect(top('The answer chips'), lessThan(top('Add')));
    expect(top('Add'), lessThan(top('Going (1)')));
    // An inter-control step between the button and the first group.
    expect(
      tester
              .getTopLeft(find.byKey(EventDetailScreen.attendeeGroupKey(going)))
              .dy -
          tester.getBottomLeft(find.byType(TextButton)).dy,
      BgeTokens.standard.spaceMd,
    );
    expect(
      tester.getSize(find.byType(TextButton)).width,
      lessThan(
        tester.getSize(find.byKey(EventDetailScreen.attendeesKey)).width,
      ),
    );
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

  group("a row's menu (#510)", () {
    /// The menu's items in its order, by the screen's names for them.
    const items = {
      'going': 'Going',
      'maybe': 'Maybe',
      'notGoing': 'Not going',
      'remove': 'Remove from event',
    };

    Finder menuOf(String id) =>
        find.byKey(EventDetailScreen.attendeeMenuKey(id));

    Finder itemOf(String id, String item) =>
        find.byKey(EventDetailScreen.attendeeActionKey(id, item));

    MenuItemButton itemWidget(WidgetTester tester, String id, String item) =>
        tester.widget(itemOf(id, item));

    /// What row [id]'s open menu offers, in its order. Only the open menu
    /// builds its items.
    List<String> offered(WidgetTester tester, String id) => [
      for (final item in tester.widgetList<MenuItemButton>(
        find.byType(MenuItemButton),
      ))
        for (final name in items.keys)
          if (item.key == EventDetailScreen.attendeeActionKey(id, name)) name,
    ];

    /// Opens or closes row [id]'s menu.
    Future<void> toggle(WidgetTester tester, String id) async {
      await tester.tap(menuOf(id));
      await tester.pumpAndSettle();
    }

    /// Picks [item] from row [id]'s open menu. Its press lands after the
    /// frame the tap ends in.
    Future<void> pick(WidgetTester tester, String id, String item) async {
      await tester.tap(itemOf(id, item));
      await tester.pump();
      await tester.pumpAndSettle();
    }

    Finder rowOf(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(MergeSemantics),
    );

    testWidgets('a row the viewer may act on has a menu beside it', (
      tester,
    ) async {
      final answered = <(String, EventParticipationStatus)>[];
      final removed = <String>[];
      await pump(
        tester,
        [
          _who('1', 'Ann', going),
          _who('2', 'Bob', maybe),
          // No name to show, but a role and an answer.
          EventAttendee(
            id: '3',
            eventId: 'e-1',
            role: EventRole.participant,
            status: invited,
            createdAt: kItemInstant,
            updatedAt: kItemInstant,
          ),
        ],
        reach: AttendeeReach.allRoles,
        viewerAttendeeId: 'me',
        enabled: true,
        onAnswer: (row, answer) => answered.add((row.id, answer)),
        onRemove: (row) => removed.add(row.id),
      );

      expect(menuOf('1'), findsOneWidget);
      expect(menuOf('2'), findsOneWidget);
      expect(menuOf('3'), findsOneWidget);
      // At the row's end, level with its first line.
      final menu = tester.getRect(menuOf('1'));
      final name = tester.getRect(find.text('Ann'));
      expect(menu.left, greaterThanOrEqualTo(name.right));
      expect(menu.top, lessThan(name.bottom));
      // Beside the row's node, not in it: a screen reader reaches it as a
      // control of its own, named for whose it is.
      expect(
        find.descendant(of: rowOf('Ann'), matching: menuOf('1')),
        findsNothing,
      );
      expect(
        tester.getSemantics(find.text('Ann')).label,
        isNot(contains('Actions')),
      );
      expect(find.byTooltip('Actions for Ann'), findsOneWidget);
      expect(find.byTooltip('Actions for Bob'), findsOneWidget);
      expect(find.byTooltip('Actions for this person'), findsOneWidget);

      await toggle(tester, '1');
      expect(offered(tester, '1'), items.keys.toList());
      for (final MapEntry(key: item, value: label) in items.entries) {
        expect(
          find.descendant(of: itemOf('1', item), matching: find.text(label)),
          findsOneWidget,
          reason: item,
        );
      }

      await pick(tester, '1', 'maybe');
      expect(answered, [('1', maybe)]);
      expect(removed, isEmpty);

      await toggle(tester, '1');
      await pick(tester, '1', 'remove');
      expect(removed, ['1']);
      expect(answered, hasLength(1));
    });

    testWidgets("a row's menu keeps its focus when a group above it goes", (
      tester,
    ) async {
      Future<void> show(List<EventAttendee> rows) => pump(
        tester,
        rows,
        reach: AttendeeReach.allRoles,
        viewerAttendeeId: 'me',
        enabled: true,
        onAnswer: (_, _) {},
        onRemove: (_) {},
      );
      FocusNode focusOf(String id) => Focus.of(
        tester.element(
          find.descendant(
            of: menuOf(id),
            matching: find.byIcon(Icons.more_vert),
          ),
        ),
      );

      await show([_who('1', 'Ann', going), _who('2', 'Bob', maybe)]);
      final focus = focusOf('2')..requestFocus();
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);

      // Ann leaves, and Going with her: Maybe is now the first group.
      await show([_who('2', 'Bob', maybe)]);

      expect(find.text('Going (1)'), findsNothing);
      expect(focusOf('2'), same(focus));
      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets("the viewer's own row has no menu", (tester) async {
      final rows = [_who('1', 'Me', going), _who('2', 'Bob', going)];
      await pump(
        tester,
        rows,
        reach: AttendeeReach.allRoles,
        viewerAttendeeId: '1',
        enabled: true,
        onAnswer: (_, _) {},
        onRemove: (_) {},
      );

      // Their chips answer for them, and leaving is #512's.
      expect(menuOf('1'), findsNothing);
      expect(menuOf('2'), findsOneWidget);

      // Nor does anyone's without reach over the roster.
      await pump(
        tester,
        rows,
        viewerAttendeeId: '1',
        enabled: true,
        onAnswer: (_, _) {},
        onRemove: (_) {},
      );
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets("the host's row offers answers but no Remove to a co-host", (
      tester,
    ) async {
      await pump(
        tester,
        [
          _who('h', 'Hal', going, role: EventRole.host),
          _who('p', 'Pat', going),
        ],
        reach: AttendeeReach.allRoles,
        viewerAttendeeId: 'me',
        enabled: true,
        onAnswer: (_, _) {},
        onRemove: (_) {},
      );

      await toggle(tester, 'h');
      expect(offered(tester, 'h'), ['going', 'maybe', 'notGoing']);
      expect(itemOf('h', 'remove'), findsNothing);
      await toggle(tester, 'h');

      await toggle(tester, 'p');
      expect(offered(tester, 'p'), items.keys.toList());
    });

    testWidgets("an organizer sees no Remove on a co-host's row", (
      tester,
    ) async {
      await pump(
        tester,
        [
          _who('c', 'Cleo', going, role: EventRole.coHost),
          _who('m', 'Mo', going, role: EventRole.moderator),
          _who('s', 'Sam', going, role: EventRole.spectator),
        ],
        reach: AttendeeReach.attendingRoles,
        viewerAttendeeId: 'me',
        enabled: true,
        onAnswer: (_, _) {},
        onRemove: (_) {},
      );

      // They answer for anyone, and remove only those who attend.
      for (final (id, expected) in [
        ('c', ['going', 'maybe', 'notGoing']),
        ('m', ['going', 'maybe', 'notGoing']),
        ('s', items.keys.toList()),
      ]) {
        await toggle(tester, id);
        expect(offered(tester, id), expected, reason: id);
        await toggle(tester, id);
      }
    });

    testWidgets('the current answer is in the menu, disabled', (tester) async {
      final answered = <EventParticipationStatus>[];
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        [_who('1', 'Ann', maybe)],
        reach: AttendeeReach.allRoles,
        viewerAttendeeId: 'me',
        enabled: true,
        onAnswer: (_, answer) => answered.add(answer),
        onRemove: (_) {},
      );

      await toggle(tester, '1');
      expect(offered(tester, '1'), items.keys.toList());
      expect(itemWidget(tester, '1', 'maybe').onPressed, isNull);
      expect(
        (itemWidget(tester, '1', 'maybe').leadingIcon! as Icon).icon,
        Icons.check,
      );
      // The check is only drawn, so the item says it is the one chosen.
      expect(
        tester.getSemantics(itemOf('1', 'maybe')),
        isSemantics(label: 'Maybe', isSelected: true, isEnabled: false),
      );
      for (final item in ['going', 'notGoing', 'remove']) {
        expect(itemWidget(tester, '1', item).onPressed, isNotNull);
        // An empty icon, which keeps the labels in line.
        expect(
          (itemWidget(tester, '1', item).leadingIcon! as Icon).icon,
          isNull,
          reason: item,
        );
      }
      expect(
        tester.getSemantics(itemOf('1', 'going')),
        isSemantics(label: 'Going', isSelected: false, isEnabled: true),
      );

      await tester.tap(itemOf('1', 'maybe'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(answered, isEmpty);
      handle.dispose();
    });

    testWidgets("offline, the menu's items are disabled and send nothing", (
      tester,
    ) async {
      var sent = 0;
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        [_who('1', 'Ann', going)],
        reach: AttendeeReach.allRoles,
        viewerAttendeeId: 'me',
        enabled: true,
        onAnswer: (_, _) => sent++,
        onRemove: (_) => sent++,
        offline: true,
      );

      // The button opens the menu, so its items can be read.
      expect(tester.widget<IconButton>(menuOf('1')).onPressed, isNotNull);
      await toggle(tester, '1');
      for (final MapEntry(key: item, value: label) in items.entries) {
        expect(itemWidget(tester, '1', item).onPressed, isNull, reason: item);
        // Each says why, as its own second line, read with it.
        expect(
          tester.getSemantics(itemOf('1', item)),
          isSemantics(label: '$label\n$_onlineOnlyCopy'),
          reason: item,
        );
        await tester.tap(itemOf('1', item), warnIfMissed: false);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(sent, 0);
      // A disabled item leaves the menu open.
      await toggle(tester, '1');
      expect(itemOf('1', 'remove'), findsNothing);

      // Online, while the screen holds them, they stay, disabled.
      await pump(
        tester,
        [_who('1', 'Ann', going)],
        reach: AttendeeReach.allRoles,
        viewerAttendeeId: 'me',
        onAnswer: (_, _) => sent++,
        onRemove: (_) => sent++,
      );
      await toggle(tester, '1');
      for (final item in items.keys) {
        expect(itemWidget(tester, '1', item).onPressed, isNull, reason: item);
      }
      expect(find.text(_onlineOnlyCopy), findsNothing);
      handle.dispose();
    });

    testWidgets(
      'at 320dp and 2.0 text a long name wraps and the menu button stays on '
      'screen',
      (tester) async {
        const long =
            'Maximiliana Theodora Featherstonehaugh-Cholmondeley of Little '
            'Whinging';
        await pump(
          tester,
          [_who('1', long, notGoing), _who('2', 'Bob', notGoing)],
          size: const Size(320, 640),
          textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
          reach: AttendeeReach.allRoles,
          viewerAttendeeId: 'me',
          enabled: true,
          onAnswer: (_, _) {},
          onRemove: (_) {},
        );
        expect(tester.takeException(), isNull);

        const window = Rect.fromLTWH(0, 0, 320, 640);
        final menu = tester.getRect(menuOf('1'));
        expect(window.intersect(menu), menu);
        expect(menu.width, greaterThanOrEqualTo(48));
        // Wrapped in what the menu leaves it, over more lines than a short
        // name in the same style.
        final name = tester.getRect(find.text(long));
        expect(name.right, lessThanOrEqualTo(menu.left));
        expect(
          name.height,
          greaterThan(tester.getSize(find.text('Bob')).height),
        );

        // Its items wrap too, held to the screen.
        await toggle(tester, '1');
        expect(tester.takeException(), isNull);
        for (final item in items.keys) {
          final rect = tester.getRect(itemOf('1', item));
          expect(window.intersect(rect), rect, reason: item);
        }
      },
    );
  });
}
