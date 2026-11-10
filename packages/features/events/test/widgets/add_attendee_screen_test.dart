import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

import '../support/fake_user_remote.dart';

const _onlineOnlyCopy = "Available when you're online";

const _ada = UserSummary(
  id: 'u-ada',
  username: 'ada',
  displayName: 'Ada Lovelace',
);
const _bo = UserSummary(id: 'u-bo', username: 'bo');
const _cy = UserSummary(id: 'u-cy', username: 'cy', displayName: 'Cy');

/// Someone whose username is blank, as a search can answer: no name to
/// show.
const _nameless = UserSummary(id: 'u-nameless', username: ' ');

/// What a host's page is opened with: every role they may give, and Bo and
/// the nameless user already on the event.
final _hostArgs = AddAttendeeArgs(
  roles: assignableEventRoles(AttendeeReach.allRoles),
  rosterUserIds: {_bo.id, _nameless.id},
);

/// An organizer's: those who attend.
final _organizerArgs = AddAttendeeArgs(
  roles: assignableEventRoles(AttendeeReach.attendingRoles),
  rosterUserIds: {_bo.id},
);

/// Each role's label and the line under it.
const Map<EventRole, (String, String)> _roles = {
  EventRole.participant: (
    'Participant',
    'Answers, votes on dates and games, and brings games.',
  ),
  EventRole.guest: (
    'Guest',
    "Answers and votes on dates. Can't nominate or vote on games.",
  ),
  EventRole.spectator: (
    'Spectator',
    "Comes to watch. Answers whether they're coming, and has no vote.",
  ),
  EventRole.coHost: (
    'Co-host',
    "Runs the event with you: its dates, people and games. Can't delete it.",
  ),
  EventRole.organizer: (
    'Organizer',
    'Edits the event, proposes dates, and adds or removes participants, '
        'guests and spectators.',
  ),
  EventRole.moderator: (
    'Moderator',
    'Edits the event and its dates, settles nominations, and adds or removes '
        'participants, guests and spectators.',
  ),
};

/// The Add people page (#510): the search and its one pick, someone already
/// on the event, the roles the viewer may give, and Add, which pops the pick
/// and the role for the event's screen to send.
void main() {
  late FakeUserRemote users;

  /// Whether the page has popped, and what with.
  late bool popped;
  late EventAttendeeAddition? popResult;

  setUp(() {
    users = FakeUserRemote()
      ..onSearchUsers = (_) async => pageOf([_ada, _bo, _cy, _nameless]);
    popped = false;
    popResult = null;
  });

  /// The page, pushed above a page of its own as the shell pushes it, so
  /// that what it pops with can be read. [textScaler], when given, overrides
  /// the scale the view gives the app.
  Widget harness({
    AddAttendeeArgs? args,
    bool offline = false,
    TextScaler? textScaler,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: const [
      ...EventsLocalizations.localizationsDelegates,
      UserSearchLocalizations.delegate,
    ],
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) => BgeConnectivityScope(
      offline: offline,
      noticeShowing: offline,
      onlineOnlyReason: _onlineOnlyCopy,
      child: textScaler == null
          ? child!
          : MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
    ),
    home: Builder(
      builder: (context) {
        Future<void> open() async {
          popResult = await Navigator.of(context).push<EventAttendeeAddition>(
            MaterialPageRoute(
              builder: (_) =>
                  AddAttendeeScreen(users: users, args: args ?? _hostArgs),
            ),
          );
          popped = true;
        }

        return Scaffold(
          body: TextButton(
            onPressed: () => unawaited(open()),
            child: const Text('open'),
          ),
        );
      },
    ),
  );

  Future<void> show(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAttendeeScreen), findsOneWidget);
  }

  Future<void> open(
    WidgetTester tester, {
    AddAttendeeArgs? args,
    bool offline = false,
    TextScaler? textScaler,
  }) async {
    await tester.pumpWidget(
      harness(args: args, offline: offline, textScaler: textScaler),
    );
    await show(tester);
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  /// Types [query] into the search and waits out its pause.
  Future<void> search(WidgetTester tester, String query) async {
    await reveal(tester, find.byKey(AddAttendeeScreen.searchKey));
    await tester.enterText(find.byKey(AddAttendeeScreen.searchKey), query);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  /// Taps [user]'s row among the results.
  Future<void> pick(WidgetTester tester, UserSummary user) async {
    final row = find.byKey(AddAttendeeScreen.resultKey(user.id));
    await reveal(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Future<void> chooseRole(WidgetTester tester, EventRole role) async {
    final option = find.byKey(AddAttendeeScreen.roleKey(role));
    await reveal(tester, option);
    await tester.tap(option);
    await tester.pumpAndSettle();
  }

  FilledButton addButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.descendant(
      of: find.byKey(AddAttendeeScreen.addKey),
      matching: find.byType(FilledButton),
    ),
  );

  Future<void> tapAdd(WidgetTester tester) async {
    final add = find.byKey(AddAttendeeScreen.addKey);
    await reveal(tester, add);
    await tester.tap(add, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  bool selected(WidgetTester tester, UserSummary user) => tester
      .widget<ListTile>(find.byKey(AddAttendeeScreen.resultKey(user.id)))
      .selected;

  Finder inAlreadyOn(String text) => find.descendant(
    of: find.byKey(AddAttendeeScreen.alreadyOnKey),
    matching: find.text(text),
  );

  testWidgets('Participant is preselected', (tester) async {
    await open(tester);

    expect(find.text('Add people'), findsOneWidget);
    expect(
      tester.getSemantics(
        find.byKey(AddAttendeeScreen.roleKey(EventRole.participant)),
      ),
      // Read with the line under it.
      isSemantics(
        label:
            'Participant\nAnswers, votes on dates and games, and brings games.',
        isChecked: true,
        isInMutuallyExclusiveGroup: true,
      ),
    );
    for (final role in _roles.keys.skip(1)) {
      expect(
        tester.getSemantics(find.byKey(AddAttendeeScreen.roleKey(role))),
        isSemantics(isChecked: false),
        reason: '$role',
      );
    }
  });

  testWidgets("an organizer's page offers only participant, guest and "
      'spectator', (tester) async {
    await open(tester, args: _organizerArgs);

    final offered = [
      EventRole.participant,
      EventRole.guest,
      EventRole.spectator,
    ];
    // In that order, each with its label and the line under it.
    var above = double.negativeInfinity;
    for (final role in offered) {
      final option = find.byKey(AddAttendeeScreen.roleKey(role));
      expect(option, findsOneWidget, reason: '$role');
      final (label, description) = _roles[role]!;
      for (final text in [label, description]) {
        expect(
          find.descendant(of: option, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
      final top = tester.getTopLeft(option).dy;
      expect(top, greaterThan(above), reason: '$role');
      above = top;
    }
    for (final role in [
      EventRole.coHost,
      EventRole.organizer,
      EventRole.moderator,
    ]) {
      expect(
        find.byKey(AddAttendeeScreen.roleKey(role)),
        findsNothing,
        reason: '$role',
      );
    }
    expect(find.text('Co-host'), findsNothing);

    // A host's offers all six, each described.
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester);
    for (final MapEntry(key: role, value: (label, description))
        in _roles.entries) {
      final option = find.byKey(AddAttendeeScreen.roleKey(role));
      for (final text in [label, description]) {
        expect(
          find.descendant(of: option, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
    }
  });

  testWidgets('Add is disabled until someone is picked', (tester) async {
    await open(tester);
    expect(addButton(tester).onPressed, isNull);

    await search(tester, 'ad');
    expect(users.calls, ['searchUsers(ad)']);
    expect(addButton(tester).onPressed, isNull);

    await pick(tester, _ada);
    expect(selected(tester, _ada), isTrue);
    expect(addButton(tester).onPressed, isNotNull);

    // Another pick takes its place: one person at a time.
    await pick(tester, _cy);
    expect(selected(tester, _ada), isFalse);
    expect(selected(tester, _cy), isTrue);

    // A new search drops it, as it may not be among the results.
    await search(tester, 'cyr');
    expect(addButton(tester).onPressed, isNull);
    expect(selected(tester, _cy), isFalse);
  });

  testWidgets("picking someone already on says so and doesn't select them", (
    tester,
  ) async {
    await open(tester);
    await search(tester, 'bo');
    await pick(tester, _ada);

    await pick(tester, _bo);

    expect(inAlreadyOn('bo is already on this event.'), findsOneWidget);
    expect(selected(tester, _bo), isFalse);
    // Nor is the pick before them kept, for Add to send instead.
    expect(selected(tester, _ada), isFalse);
    expect(addButton(tester).onPressed, isNull);
    // Announced, and brought into view, between the field and the results.
    final note = tester.widget<BgeInlineBanner>(
      find.byKey(AddAttendeeScreen.alreadyOnKey),
    );
    expect(note.announce, isTrue);
    expect(note.reveal, isTrue);
    expect(
      tester.getTopLeft(find.byKey(AddAttendeeScreen.alreadyOnKey)).dy,
      greaterThan(
        tester.getBottomLeft(find.byKey(AddAttendeeScreen.searchKey)).dy,
      ),
    );
    expect(
      tester.getBottomLeft(find.byKey(AddAttendeeScreen.alreadyOnKey)).dy,
      lessThan(
        tester.getTopLeft(find.byKey(AddAttendeeScreen.resultKey(_ada.id))).dy,
      ),
    );

    // Someone with no name to show is named for what they are.
    await pick(tester, _nameless);
    expect(
      inAlreadyOn('This person is already on this event.'),
      findsOneWidget,
    );

    // A pick that can be added takes the note away.
    await pick(tester, _ada);
    expect(find.byKey(AddAttendeeScreen.alreadyOnKey), findsNothing);
    expect(selected(tester, _ada), isTrue);
    expect(addButton(tester).onPressed, isNotNull);

    // So does a new search.
    await pick(tester, _bo);
    expect(find.byKey(AddAttendeeScreen.alreadyOnKey), findsOneWidget);
    await search(tester, 'bob');
    expect(find.byKey(AddAttendeeScreen.alreadyOnKey), findsNothing);
  });

  testWidgets('Add pops the pick and the role', (tester) async {
    await open(tester);
    await search(tester, 'ad');
    await pick(tester, _ada);
    await chooseRole(tester, EventRole.guest);

    await tapAdd(tester);

    expect(popped, isTrue);
    expect(
      popResult,
      const EventAttendeeAddition(user: _ada, role: EventRole.guest),
    );
    expect(find.byType(AddAttendeeScreen), findsNothing);
  });

  testWidgets('back pops nothing', (tester) async {
    await open(tester);
    await search(tester, 'ad');
    await pick(tester, _ada);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(popped, isTrue);
    expect(popResult, isNull);
  });

  testWidgets('offline, Add is disabled and pops nothing', (tester) async {
    await open(tester, offline: true);
    await search(tester, 'ad');
    await pick(tester, _ada);
    expect(selected(tester, _ada), isTrue);

    expect(addButton(tester).onPressed, isNull);
    // It says why, once under it and as its hint.
    expect(find.text(_onlineOnlyCopy), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(_onlineOnlyCopy)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byType(FilledButton)).dy),
    );
    expect(
      tester.getSemantics(find.byKey(AddAttendeeScreen.addKey)),
      isSemantics(hint: _onlineOnlyCopy, isEnabled: false),
    );
    await tapAdd(tester);

    expect(popped, isFalse);
    expect(find.byType(AddAttendeeScreen), findsOneWidget);
  });

  testWidgets("at 320dp and 2.0 text each role's description wraps", (
    tester,
  ) async {
    useViewSize(tester, const Size(320, 640));
    await open(
      tester,
      textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
    );
    await search(tester, 'ad');
    await pick(tester, _ada);
    expect(tester.takeException(), isNull);

    for (final MapEntry(key: role, value: (label, description))
        in _roles.entries) {
      final option = find.byKey(AddAttendeeScreen.roleKey(role));
      await reveal(tester, option);
      final line = find.descendant(
        of: option,
        matching: find.text(description),
      );
      final rect = tester.getRect(line);
      // Inside the window, and taller than its one-word label: it runs on
      // to more lines rather than off the edge.
      expect(rect.left, greaterThanOrEqualTo(0), reason: description);
      expect(rect.right, lessThanOrEqualTo(320), reason: description);
      expect(
        rect.height,
        greaterThan(
          tester
                  .getSize(
                    find.descendant(of: option, matching: find.text(label)),
                  )
                  .height *
              2,
        ),
        reason: description,
      );
    }

    // Add stays within the window too.
    final add = find.byKey(AddAttendeeScreen.addKey);
    await reveal(tester, add);
    final rect = tester.getRect(add);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
  });

  group('accessibility audit', () {
    Widget build(ThemeData theme) => harness(theme: theme);

    Widget buildOffline(ThemeData theme) =>
        harness(theme: theme, offline: true);

    Future<void> picked(WidgetTester tester) async {
      await show(tester);
      await search(tester, 'ad');
      await pick(tester, _ada);
      expect(selected(tester, _ada), isTrue);
    }

    Future<void> alreadyOn(WidgetTester tester) async {
      await show(tester);
      await search(tester, 'bo');
      await pick(tester, _bo);
      expect(find.byKey(AddAttendeeScreen.alreadyOnKey), findsOneWidget);
    }

    // At 320dp × 2.0 the results and the roles run several screens tall,
    // and a scroll that shows the end leaves a row half under the top edge,
    // which Flutter's tap-target check fails at its clipped size, a limit
    // of the tool. So each state is audited as reached, and in a view tall
    // enough for the whole page.
    Future<void> wholePage(
      WidgetTester tester,
      Future<void> Function(WidgetTester) reach,
    ) async {
      await useWholePage(tester);
      await reach(tester);
      await tester.pumpAndSettle();
      expectWholePage(tester);
    }

    auditScreen('ready', build: build, arrange: show);

    // Add is on screen, disabled until someone is picked and dimmed by
    // design: WCAG 1.4.3 exempts inactive controls. Online, its
    // `BgeOnlineOnly` merge has no disabled state of its own, which is what
    // the guideline reads, so it measures the label (#50). The page's other
    // text is measured in 'ready' and 'picked, whole page'.
    auditScreen(
      'ready, whole page',
      build: build,
      arrange: (tester) => wholePage(tester, show),
      textContrast: false,
    );

    auditScreen(
      'picked, whole page',
      build: build,
      arrange: (tester) => wholePage(tester, picked),
    );

    auditScreen(
      'someone already on',
      build: build,
      arrange: (tester) async {
        await alreadyOn(tester);
        // The note brought itself into view, which can leave the field
        // half under the top edge.
        await scrollPageToTop(tester);
      },
    );

    // As 'ready, whole page': Add is disabled, with no one picked. The
    // note's own text is measured in 'someone already on'.
    auditScreen(
      'someone already on, whole page',
      build: build,
      arrange: (tester) => wholePage(tester, alreadyOn),
      textContrast: false,
    );

    auditScreen(
      'offline, picked, whole page',
      build: buildOffline,
      arrange: (tester) => wholePage(tester, picked),
    );
  });
}
