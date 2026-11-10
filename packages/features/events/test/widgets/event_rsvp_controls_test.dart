import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_rsvp_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

const _onlineOnlyCopy = "Available when you're online";

const EventParticipationStatus _going = EventParticipationStatus.attending;
const EventParticipationStatus _maybe = EventParticipationStatus.maybe;
const EventParticipationStatus _notGoing =
    EventParticipationStatus.notAttending;
const EventParticipationStatus _invited = EventParticipationStatus.invited;
const EventParticipationStatus _unknown = EventParticipationStatus.unknown;

/// The answers that have a chip, in the order they show.
const List<(EventParticipationStatus, String)> _answers = [
  (_going, 'Going'),
  (_maybe, 'Maybe'),
  (_notGoing, 'Not going'),
];

/// The viewer's own row on the roster.
EventAttendee _me(EventParticipationStatus status, {String? notes}) =>
    EventAttendee(
      id: 'att-me',
      eventId: 'e-1',
      userId: 'u-me',
      role: EventRole.participant,
      status: status,
      notes: notes,
      createdAt: kItemInstant,
      updatedAt: kItemInstant,
    );

Finder _chip(EventParticipationStatus status) =>
    find.byKey(EventDetailScreen.rsvpAnswerKey(status));

final Finder _noteButton = find.byKey(EventDetailScreen.rsvpNoteKey);

ChoiceChip _chipOf(WidgetTester tester, EventParticipationStatus status) =>
    tester.widget<ChoiceChip>(_chip(status));

TextButton _noteOf(WidgetTester tester) =>
    tester.widget<TextButton>(_noteButton);

FocusNode _chipFocus(WidgetTester tester, EventParticipationStatus status) =>
    _chipOf(tester, status).focusNode!;

FocusNode _noteFocus(WidgetTester tester) => _noteOf(tester).focusNode!;

/// Moves focus to [node] and presses Enter on it, as a keyboard user would.
Future<void> _pressWithKeys(WidgetTester tester, FocusNode node) async {
  node.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

/// The viewer's answer chips and note button (#508).
void main() {
  late List<EventParticipationStatus> answers;
  late int notes;
  // What each press's callback answers: whether its write was sent.
  late bool sends;

  setUp(() {
    answers = [];
    notes = 0;
    sends = true;
  });

  Widget host(
    EventAttendee attendee, {
    bool enabled = true,
    bool busy = false,
    bool offline = false,
    TextScaler textScaler = TextScaler.noScaling,
    EdgeInsets padding = EdgeInsets.zero,
  }) => MaterialApp(
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
        padding: padding,
        child: EventRsvpControls(
          attendee: attendee,
          enabled: enabled,
          busy: busy,
          onAnswer: (status) async {
            answers.add(status);
            return sends;
          },
          onEditNote: () async {
            notes++;
            return sends;
          },
        ),
      ),
    ),
  );

  /// Every control is disabled: no chip or note button takes a press.
  void expectAllDisabled(WidgetTester tester, {String? reason}) {
    for (final (status, label) in _answers) {
      expect(_chipOf(tester, status).onSelected, isNull, reason: label);
    }
    expect(_noteOf(tester).onPressed, isNull, reason: reason);
  }

  testWidgets(
    "shows Going, Maybe and Not going, with the viewer's answer selected",
    (tester) async {
      for (final (status, chosen) in [
        (_going, _going),
        (_maybe, _maybe),
        (_notGoing, _notGoing),
        (_invited, null),
      ]) {
        await tester.pumpWidget(host(_me(status)));

        for (final (answer, label) in _answers) {
          expect(
            find.descendant(of: _chip(answer), matching: find.text(label)),
            findsOneWidget,
          );
          expect(
            _chipOf(tester, answer).selected,
            answer == chosen,
            reason: '$status: $label',
          );
          expect(_chipOf(tester, answer).onSelected, isNotNull);
        }
        expect(_chip(_invited), findsNothing);
        expect(find.text('Invited'), findsNothing);
      }

      final lefts = [
        for (final (status, _) in _answers) tester.getTopLeft(_chip(status)).dx,
      ];
      expect([...lefts]..sort(), lefts);
    },
  );

  testWidgets('a press calls onAnswer with its status', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(_me(_invited)));
    await tester.tap(_chip(_maybe));
    await tester.pump();
    expect(answers, [_maybe]);

    // The chosen answer pressed again, by a pointer or by a screen reader's
    // tap, changes nothing.
    await tester.pumpWidget(host(_me(_maybe)));
    await tester.tap(_chip(_maybe));
    tester.semantics.tap(find.semantics.byLabel('Maybe'));
    await tester.pump();
    expect(answers, [_maybe]);

    await tester.tap(_chip(_notGoing));
    await tester.pump();
    expect(answers, [_maybe, _notGoing]);
    handle.dispose();
  });

  testWidgets('the pressed answer stays focused and inert while it is out', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(_me(_invited)));
    await _pressWithKeys(tester, _chipFocus(tester, _maybe));
    expect(answers, [_maybe]);

    await tester.pumpWidget(host(_me(_invited), busy: true));
    expect(_chipFocus(tester, _maybe).hasPrimaryFocus, isTrue);
    expect(_chipOf(tester, _maybe).onSelected, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(_chip(_maybe));
    await tester.pump();
    expect(answers, [_maybe]);

    expect(_chipOf(tester, _going).onSelected, isNull);
    expect(_chipOf(tester, _notGoing).onSelected, isNull);
    expect(_noteOf(tester).onPressed, isNull);

    // Its node keeps its selected state, with its focus, and says it isn't
    // enabled, with no tap, and why. The chip still shows the answer alone.
    // The others are disabled, and can't take focus.
    expect(find.text('Maybe'), findsOneWidget);
    expect(
      tester.getSemantics(_chip(_maybe)),
      isSemantics(
        label: 'Maybe, saving your answer…',
        isButton: true,
        hasSelectedState: true,
        isSelected: false,
        hasEnabledState: true,
        isEnabled: false,
        isFocusable: true,
        isFocused: true,
        hasTapAction: false,
        hasFocusAction: true,
      ),
    );
    for (final (status, label) in [
      (_going, 'Going'),
      (_notGoing, 'Not going'),
    ]) {
      expect(
        tester.getSemantics(_chip(status)),
        isSemantics(
          label: label,
          isButton: true,
          hasSelectedState: true,
          isSelected: false,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: false,
          hasTapAction: false,
          hasFocusAction: false,
        ),
        reason: label,
      );
    }
    handle.dispose();
  });

  testWidgets('once the answer lands, its chip is named by the answer alone '
      'while the read runs', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(_me(_invited)));
    await _pressWithKeys(tester, _chipFocus(tester, _maybe));

    // The write landed, and the read its outcome started still runs.
    await tester.pumpWidget(host(_me(_maybe), enabled: false));

    expect(_chipFocus(tester, _maybe).hasPrimaryFocus, isTrue);
    expect(
      tester.getSemantics(_chip(_maybe)),
      isSemantics(
        label: 'Maybe',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasEnabledState: true,
        isEnabled: false,
        isFocusable: true,
        isFocused: true,
        hasTapAction: false,
        hasFocusAction: true,
      ),
    );
    expect(_chipOf(tester, _maybe).avatar, isNull);
    handle.dispose();
  });

  testWidgets('a second press before the first one shows is ignored, and the '
      'first stays held', (tester) async {
    final handle = tester.ensureSemantics();
    for (final (name, second) in [
      ('Not going', _chip(_notGoing)),
      ('the note', _noteButton),
    ]) {
      await tester.pumpWidget(host(_me(_invited)));
      _chipFocus(tester, _going).requestFocus();
      await tester.pump();

      // Both inside one frame: Going by keys, then the other by a tap.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.tap(second);
      expect(answers, [_going], reason: name);
      expect(notes, 0, reason: name);

      // Going's write goes out: Going is held, focused and inert, and the
      // rest are disabled.
      await tester.pumpWidget(host(_me(_invited), busy: true));
      expect(_chipFocus(tester, _going).hasPrimaryFocus, isTrue, reason: name);
      expect(_chipOf(tester, _going).onSelected, isNotNull, reason: name);
      expect(_chipOf(tester, _notGoing).onSelected, isNull, reason: name);
      expect(_noteOf(tester).onPressed, isNull, reason: name);
      expect(
        tester.getSemantics(_chip(_going)),
        isSemantics(
          label: 'Going, saving your answer…',
          isButton: true,
          hasSelectedState: true,
          isSelected: false,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          isFocused: true,
          hasTapAction: false,
          hasFocusAction: true,
        ),
        reason: name,
      );

      answers.clear();
      await tester.pumpWidget(const SizedBox.shrink());
    }
    handle.dispose();
  });

  testWidgets('the pressed answer keeps focus through the read its answer '
      'starts', (tester) async {
    await tester.pumpWidget(host(_me(_invited)));
    await _pressWithKeys(tester, _chipFocus(tester, _going));
    expect(answers, [_going]);

    // The write, then the read its outcome starts.
    for (final (enabled, busy) in [(false, true), (false, false)]) {
      await tester.pumpWidget(
        host(_me(_invited), enabled: enabled, busy: busy),
      );
      final reason = 'enabled: $enabled, busy: $busy';
      expect(
        _chipFocus(tester, _going).hasPrimaryFocus,
        isTrue,
        reason: reason,
      );
      expect(_chipOf(tester, _going).onSelected, isNotNull, reason: reason);
      expect(_chipOf(tester, _maybe).onSelected, isNull, reason: reason);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(answers, [_going], reason: reason);
    }

    // The read found the answer unchanged, so Going can be sent again.
    await tester.pumpWidget(host(_me(_invited)));
    expect(_chipFocus(tester, _going).hasPrimaryFocus, isTrue);
    expect(_chipOf(tester, _maybe).onSelected, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(answers, [_going, _going]);
  });

  testWidgets('the note button stays focused and inert while its note is out', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final me = _me(_going, notes: 'Bringing snacks');
    await tester.pumpWidget(host(me));
    await _pressWithKeys(tester, _noteFocus(tester));
    expect(notes, 1);

    for (final (enabled, busy) in [(false, true), (false, false)]) {
      await tester.pumpWidget(host(me, enabled: enabled, busy: busy));
      final reason = 'enabled: $enabled, busy: $busy';
      expect(_noteFocus(tester).hasPrimaryFocus, isTrue, reason: reason);
      expect(_noteOf(tester).onPressed, isNotNull, reason: reason);
      for (final (status, label) in _answers) {
        expect(_chipOf(tester, status).onSelected, isNull, reason: label);
      }
      expect(
        tester.getSemantics(_noteButton),
        isSemantics(
          label: 'Saving your note…',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          isFocused: true,
          hasTapAction: false,
        ),
        reason: reason,
      );
      expect(
        find.descendant(
          of: _noteButton,
          matching: find.text('Saving your note…'),
        ),
        findsOneWidget,
        reason: reason,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(notes, 1, reason: reason);
    }

    await tester.pumpWidget(host(me));
    expect(_noteFocus(tester).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(notes, 2);
    handle.dispose();
  });

  testWidgets('a press that sent nothing leaves no control inert', (
    tester,
  ) async {
    // A dialog cancelled, or the write dropped.
    sends = false;
    for (final (name, focus) in <(String, FocusNode Function(WidgetTester))>[
      ('Maybe', (tester) => _chipFocus(tester, _maybe)),
      ('the note', _noteFocus),
    ]) {
      await tester.pumpWidget(host(_me(_going)));
      await _pressWithKeys(tester, focus(tester));

      // Another control's request goes out.
      await tester.pumpWidget(host(_me(_going), busy: true));
      expectAllDisabled(tester, reason: name);
    }
    expect(answers, [_maybe]);
    expect(notes, 1);
  });

  testWidgets('a write that ended before the controls saw it out leaves no '
      'control inert', (tester) async {
    await tester.pumpWidget(host(_me(_going)));
    await _pressWithKeys(tester, _chipFocus(tester, _maybe));
    expect(answers, [_maybe]);

    // Its request and outcome both landed before the next frame, which
    // built the controls available.
    await tester.pumpWidget(host(_me(_going)));

    // Another control's request goes out.
    await tester.pumpWidget(host(_me(_going), busy: true));
    expectAllDisabled(tester);
  });

  testWidgets('while a read runs with nothing pressed, every control is '
      'disabled', (tester) async {
    await tester.pumpWidget(host(_me(_going), enabled: false));
    expectAllDisabled(tester);
  });

  testWidgets(
    'offline, every chip and the note button are disabled, with one note '
    'under the group',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(_me(_going), offline: true));

      expectAllDisabled(tester);
      for (final (status, label) in _answers) {
        expect(
          tester.getSemantics(_chip(status)),
          isSemantics(
            label: label,
            hint: _onlineOnlyCopy,
            isButton: true,
            hasSelectedState: true,
            isSelected: status == _going,
            hasEnabledState: true,
            isEnabled: false,
            isFocusable: false,
            hasTapAction: false,
          ),
          reason: label,
        );
      }
      expect(
        tester.getSemantics(_noteButton),
        isSemantics(
          label: 'Add a note',
          hint: _onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: false,
          hasTapAction: false,
        ),
      );
      expect(find.text(_onlineOnlyCopy), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_onlineOnlyCopy)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(_noteButton).dy),
      );

      await tester.pumpWidget(host(_me(_going)));
      expect(find.text(_onlineOnlyCopy), findsNothing);
      for (final (status, label) in _answers) {
        expect(_chipOf(tester, status).onSelected, isNotNull, reason: label);
      }
      expect(_noteOf(tester).onPressed, isNotNull);
      handle.dispose();
    },
  );

  testWidgets('offline, the control held after its press is disabled too', (
    tester,
  ) async {
    await tester.pumpWidget(host(_me(_invited)));
    await _pressWithKeys(tester, _chipFocus(tester, _maybe));

    // No press of its own took the connection.
    await tester.pumpWidget(host(_me(_invited), busy: true, offline: true));
    expectAllDisabled(tester);

    // Back online with its write still out, it is held again.
    await tester.pumpWidget(host(_me(_invited), busy: true));
    expect(_chipOf(tester, _maybe).onSelected, isNotNull);
    expect(_chipOf(tester, _going).onSelected, isNull);
    await tester.tap(_chip(_maybe));
    await tester.pump();
    expect(answers, [_maybe]);
  });

  testWidgets(
    'the group has the question as its label, and each chip its own node',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(_me(_maybe)));

      expect(find.bySemanticsLabel('Are you coming?'), findsOneWidget);
      final group = tester.getSemantics(
        find.bySemanticsLabel('Are you coming?'),
      );
      // Each child is a chip's merged node, as a screen reader meets it.
      final chips = <SemanticsData>[];
      group.visitChildren((node) {
        chips.add(node.getSemanticsData());
        return true;
      });
      expect(
        [for (final chip in chips) chip.label],
        ['Going', 'Maybe', 'Not going'],
      );
      for (final chip in chips) {
        expect(
          chip,
          isSemantics(
            isButton: true,
            hasSelectedState: true,
            isSelected: chip.label == 'Maybe',
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
          ),
          reason: chip.label,
        );
      }
      handle.dispose();
    },
  );

  testWidgets('the note button says Add a note with no note, and Edit note '
      'with one', (tester) async {
    for (final (note, label) in [
      (null, 'Add a note'),
      ('', 'Add a note'),
      ('Running late', 'Edit note'),
    ]) {
      await tester.pumpWidget(host(_me(_maybe, notes: note)));
      expect(
        find.descendant(of: _noteButton, matching: find.text(label)),
        findsOneWidget,
        reason: '$note',
      );
    }
  });

  testWidgets('offers no note button while the answer is unknown', (
    tester,
  ) async {
    await tester.pumpWidget(host(_me(_unknown, notes: 'Running late')));

    expect(_noteButton, findsNothing);
    for (final (status, label) in _answers) {
      expect(_chipOf(tester, status).selected, isFalse, reason: label);
      expect(_chipOf(tester, status).onSelected, isNotNull, reason: label);
    }
  });

  testWidgets('every control takes a 48dp tap at 320dp, at 1.0 and 2.0 '
      'text', (tester) async {
    // A chip draws smaller than it takes taps: its target is padded to the
    // guideline's size.
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        host(
          _me(_maybe, notes: 'Running late'),
          textScaler: TextScaler.linear(scale),
          // Clear of the edges: the guideline skips a target touching the
          // screen's or a scrollable's edge, as one partly scrolled off.
          padding: const EdgeInsets.all(16),
        ),
      );

      await expectLater(
        tester,
        meetsGuideline(androidTapTargetGuideline),
        reason: 'at $scale',
      );
    }
    handle.dispose();
  });

  testWidgets('fits at 320dp and 2.0 text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const scale = TextScaler.linear(2);
    final me = _me(_maybe, notes: 'Running late');

    void expectFits(String reason) {
      expect(tester.takeException(), isNull, reason: reason);
      final rects = [
        for (final (status, _) in _answers) tester.getRect(_chip(status)),
      ];
      for (final rect in rects) {
        expect(rect.left, greaterThanOrEqualTo(0), reason: reason);
        expect(rect.right, lessThanOrEqualTo(320), reason: reason);
        expect(rect.bottom, lessThanOrEqualTo(800), reason: reason);
      }
      // They wrap rather than clip.
      expect(
        {for (final rect in rects) rect.top},
        hasLength(greaterThan(1)),
        reason: reason,
      );
    }

    await tester.pumpWidget(host(me, textScaler: scale));
    expectFits('at rest');

    // Held, with the pressed chip showing its write under way.
    await _pressWithKeys(tester, _chipFocus(tester, _notGoing));
    await tester.pumpWidget(host(me, busy: true, textScaler: scale));
    expectFits('held');

    await tester.pumpWidget(host(me, offline: true, textScaler: scale));
    expectFits('offline');

    // The note button held, its label saying its note is being saved.
    await tester.pumpWidget(host(me, textScaler: scale));
    await _pressWithKeys(tester, _noteFocus(tester));
    await tester.pumpWidget(host(me, busy: true, textScaler: scale));
    expectFits('note held');
    expect(find.text('Saving your note…'), findsOneWidget);
    final note = tester.getRect(_noteButton);
    expect(note.left, greaterThanOrEqualTo(0));
    expect(note.right, lessThanOrEqualTo(320));
  });
}
