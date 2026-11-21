import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/add_to_lineup_dialog.dart';
import 'package:events/src/widgets/pool_row_controls.dart' show NominateScope;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

const _eventStarted =
    "None of this event's dates is still to come, so a game added now can't "
    'be taken out of the lineup.';
const _longTitle =
    'Twilight Imperium: Fourth Edition, Prophecy of Kings and the Codex '
    'Volumes';

/// The direct add's form (#519): which date it is for where it asks, Primary
/// or Filler, a Filler's longest play, the note, and what it hands back.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);
  final friday = confirmed(
    'd-1',
    DateTime(2026, 11, 6, 19),
  ).copyWith(eventId: 'e-1');

  const NominateScope wholeEvent = (scope: WholeEventScope(), date: null);
  final NominateScope onFriday = (scope: const DateScope('d-1'), date: friday);

  /// What the dialog popped with, once it has.
  var done = false;
  AddToLineupChoice? value;

  Widget app({
    required List<NominateScope> scopes,
    String title = 'Catan',
    int? Function(NominationScope scope)? fillerMaxPlayTimeOf,
    bool Function(NominationScope scope)? startedOf,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    locale: const Locale('en', 'US'),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showAddToLineupDialog(
                context,
                title: title,
                scopes: scopes,
                now: now,
                fillerMaxPlayTimeOf: fillerMaxPlayTimeOf,
                startedOf: startedOf,
              ).then((result) {
                done = true;
                value = result;
              }),
          child: const Text('Open'),
        ),
      ),
    ),
  );

  /// Opens the dialog on [scopes], with the rules' longest filler
  /// [fillerMaxPlayTime] for each, or by scope where [fillerMaxPlayTimeOf]
  /// says.
  Future<void> open(
    WidgetTester tester, {
    List<NominateScope>? scopes,
    String title = 'Catan',
    int? fillerMaxPlayTime,
    int? Function(NominationScope scope)? fillerMaxPlayTimeOf,
    bool Function(NominationScope scope)? startedOf,
    Size size = const Size(400, 800),
  }) async {
    done = false;
    value = null;
    useViewSize(tester, size);
    await tester.pumpWidget(
      app(
        scopes: scopes ?? [wholeEvent],
        title: title,
        fillerMaxPlayTimeOf: fillerMaxPlayTimeOf ?? (_) => fillerMaxPlayTime,
        startedOf: startedOf,
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  final dialog = find.byType(AlertDialog);
  Finder inDialog(Finder finder) =>
      find.descendant(of: dialog, matching: finder);
  Finder scope(String? occurrenceId) =>
      find.byKey(EventDetailScreen.addToLineupScopeKey(occurrenceId));
  Finder role(ScheduledGameRole role) =>
      find.byKey(EventDetailScreen.addToLineupRoleKey(role));
  final minutes = find.byKey(EventDetailScreen.addToLineupMinutesKey);
  final notes = find.byKey(EventDetailScreen.addToLineupNotesKey);
  final confirm = find.byKey(EventDetailScreen.addToLineupConfirmKey);

  Future<void> choose(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, Finder field, String text) async {
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  String shown(WidgetTester tester, Finder field) => tester
      .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .controller
      .text;

  testWidgets('one scope asks no date', (tester) async {
    await open(tester);

    expect(inDialog(find.text('Add Catan to the lineup')), findsOneWidget);
    expect(find.byType(RadioListTile<NominationScope>), findsNothing);
    expect(scope(null), findsNothing);
    // Primary unless the host says otherwise, with no minutes to give.
    expect(minutes, findsNothing);

    await choose(tester, confirm);

    expect(done, isTrue);
    expect(value, (
      occurrenceId: null,
      role: ScheduledGameRole.primary,
      notes: null,
      maxPlayTime: null,
    ));

    // A date's view gives its date alone: nothing to ask either.
    await open(tester, scopes: [onFriday]);
    expect(find.byType(RadioListTile<NominationScope>), findsNothing);
    await choose(tester, confirm);
    expect(value?.occurrenceId, 'd-1');

    // With no row of dates, it asks: the whole event, or the one date.
    await open(tester, scopes: [wholeEvent, onFriday]);
    expect(scope(null), findsOneWidget);
    expect(scope('d-1'), findsOneWidget);
    expect(inDialog(find.text('For the whole event')), findsOneWidget);
    expect(inDialog(find.text('For Fri, Nov 6 · 7:00 PM')), findsOneWidget);
    // The whole event is chosen as it opens.
    expect(
      tester.widget<RadioListTile<NominationScope>>(scope(null)).value,
      const WholeEventScope(),
    );
    await choose(tester, scope('d-1'));
    await choose(tester, confirm);
    expect(value?.occurrenceId, 'd-1');
  });

  testWidgets('Filler asks a whole number of minutes, at least one', (
    tester,
  ) async {
    await open(tester, fillerMaxPlayTime: 20);
    expect(minutes, findsNothing);

    await choose(tester, role(ScheduledGameRole.filler));

    // Prefilled from the event's rules.
    expect(minutes, findsOneWidget);
    expect(inDialog(find.text('Minutes')), findsOneWidget);
    expect(shown(tester, minutes), '20');

    const invalid = 'Enter a whole number of minutes, at least 1.';
    for (final typed in ['0', '1.5', '-3', 'ten', '99999999999']) {
      await enter(tester, minutes, typed);
      await choose(tester, confirm);

      expect(done, isFalse, reason: typed);
      expect(inDialog(find.text(invalid)), findsOneWidget, reason: typed);
    }

    await enter(tester, minutes, ' 45 ');
    expect(inDialog(find.text(invalid)), findsNothing);
    await choose(tester, confirm);

    expect(done, isTrue);
    expect(value, (
      occurrenceId: null,
      role: ScheduledGameRole.filler,
      notes: null,
      maxPlayTime: 45,
    ));

    // Left empty, a Filler has no longest play.
    await open(tester);
    await choose(tester, role(ScheduledGameRole.filler));
    expect(shown(tester, minutes), '');
    await choose(tester, confirm);
    expect(value?.role, ScheduledGameRole.filler);
    expect(value?.maxPlayTime, isNull);

    // Back to Primary, the minutes typed for a Filler are neither checked
    // nor sent.
    await open(tester, fillerMaxPlayTime: 20);
    await choose(tester, role(ScheduledGameRole.filler));
    await enter(tester, minutes, '0');
    await choose(tester, role(ScheduledGameRole.primary));
    expect(minutes, findsNothing);
    await choose(tester, confirm);
    expect(done, isTrue);
    expect(value?.role, ScheduledGameRole.primary);
    expect(value?.maxPlayTime, isNull);
  });

  testWidgets("a Filler's minutes follow the scope chosen, until the host "
      'changes them', (tester) async {
    // The event's rules say 20 minutes, Friday's own say 15.
    int? rules(NominationScope scope) => switch (scope) {
      WholeEventScope() => 20,
      DateScope() => 15,
    };
    await open(
      tester,
      scopes: [wholeEvent, onFriday],
      fillerMaxPlayTimeOf: rules,
    );
    // Chosen before Filler is: the field opens with Friday's.
    await choose(tester, scope('d-1'));
    await choose(tester, role(ScheduledGameRole.filler));
    expect(shown(tester, minutes), '15');

    await choose(tester, scope(null));
    expect(shown(tester, minutes), '20');
    await choose(tester, scope('d-1'));
    expect(shown(tester, minutes), '15');

    // Once the host has changed them, they are theirs.
    await enter(tester, minutes, '45');
    await choose(tester, scope(null));
    expect(shown(tester, minutes), '45');
    await choose(tester, confirm);
    expect(value, (
      occurrenceId: null,
      role: ScheduledGameRole.filler,
      notes: null,
      maxPlayTime: 45,
    ));

    // A scope whose rules give no longest filler at all, the event's or its
    // own (fillerMaxPlayTimeFor falls back to the event's before giving
    // none): the field empties, and sends none.
    await open(
      tester,
      scopes: [wholeEvent, onFriday],
      fillerMaxPlayTimeOf: (scope) => scope is WholeEventScope ? 20 : null,
    );
    await choose(tester, role(ScheduledGameRole.filler));
    expect(shown(tester, minutes), '20');
    await choose(tester, scope('d-1'));
    expect(shown(tester, minutes), '');
    await choose(tester, confirm);
    expect(value?.maxPlayTime, isNull);
  });

  testWidgets('a date that has started says up front that a game added now '
      "can't be taken out, as it is chosen", (tester) async {
    final handle = tester.ensureSemantics();
    const dateStarted =
        "This date has started, so a game added now can't be taken out of the "
        'lineup.';
    await open(
      tester,
      scopes: [wholeEvent, onFriday],
      startedOf: (scope) => scope is DateScope,
    );
    expect(find.text(dateStarted), findsNothing);

    await choose(tester, scope('d-1'));
    expect(inDialog(find.text(dateStarted)), findsOneWidget);
    // Heard as it changes with the choice.
    expect(
      tester.getSemantics(find.text(dateStarted)),
      isSemantics(label: dateStarted, isLiveRegion: true),
    );
    // Above what it is played as: before anything else is asked.
    expect(
      tester.getTopLeft(find.text(dateStarted)).dy,
      lessThan(tester.getTopLeft(role(ScheduledGameRole.primary)).dy),
    );

    await choose(tester, scope(null));
    expect(find.text(dateStarted), findsNothing);
    handle.dispose();
  });

  testWidgets('the whole event, none of whose dates is still to come, says '
      'so as it opens', (tester) async {
    await open(tester, startedOf: (scope) => scope is WholeEventScope);

    expect(inDialog(find.text(_eventStarted)), findsOneWidget);
  });

  testWidgets('blank notes send none', (tester) async {
    await open(tester);
    await enter(tester, notes, '   ');
    await choose(tester, confirm);

    expect(value?.notes, isNull);

    await open(tester);
    await enter(tester, notes, '  Bring the sleeves  ');
    await choose(tester, confirm);

    expect(value?.notes, 'Bring the sleeves');
  });

  testWidgets('Cancel adds nothing', (tester) async {
    await open(tester);
    await enter(tester, notes, 'Bring the sleeves');
    await choose(tester, inDialog(find.text('Cancel')));

    expect(done, isTrue);
    expect(value, isNull);
  });

  group('accessibility audit', () {
    auditScreen(
      'the add dialog, asking the date, for a Filler',
      pump: (tester, theme) async {
        await tester.pumpWidget(
          app(
            scopes: [wholeEvent, onFriday],
            title: _longTitle,
            fillerMaxPlayTimeOf: (_) => 20,
            theme: theme,
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      },
      arrange: (tester) async {
        await choose(tester, role(ScheduledGameRole.filler));
      },
    );

    auditScreen(
      'the add dialog, for a date that has started',
      pump: (tester, theme) async {
        await tester.pumpWidget(
          app(
            scopes: [wholeEvent, onFriday],
            title: _longTitle,
            startedOf: (scope) => scope is DateScope,
            theme: theme,
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      },
      arrange: (tester) async {
        await choose(tester, scope('d-1'));
        expect(
          find.textContaining('This date has started'),
          findsOneWidget,
        );
      },
    );

    testWidgets('at 320×640 and 200% text, it lays out with nothing clipped '
        'and every control reachable', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(
        tester,
        scopes: [wholeEvent, onFriday],
        title: _longTitle,
        fillerMaxPlayTime: 20,
        // The line that says so, as well.
        startedOf: (scope) => scope is WholeEventScope,
        size: const Size(320, 640),
      );
      await choose(tester, role(ScheduledGameRole.filler));
      // An error under the minutes, the tallest the form gets.
      await enter(tester, minutes, '0');
      await choose(tester, confirm);
      expect(tester.takeException(), isNull);

      const window = Rect.fromLTWH(0, 0, 320, 640);
      // A field's label and error are Material's own, which the test's square
      // glyphs, each one em wide, cut short in a dialog this narrow where a
      // real font fits them: each is held inside the dialog, as the rest are,
      // and the rest are held whole too.
      for (final line in ['Minutes', 'Note']) {
        final text = inDialog(find.text(line));
        expect(text, findsOneWidget, reason: line);
        final rect = tester.getRect(text);
        final box = tester.getRect(dialog);
        expect(rect.left, greaterThanOrEqualTo(box.left), reason: line);
        expect(rect.right, lessThanOrEqualTo(box.right), reason: line);
      }
      expect(
        inDialog(find.text('Enter a whole number of minutes, at least 1.')),
        findsOneWidget,
      );
      for (final line in [
        'Add $_longTitle to the lineup',
        'For the whole event',
        'For Fri, Nov 6 · 7:00 PM',
        _eventStarted,
        'Play it as',
        'Primary',
        'Filler',
        'The longest it should run. Leave it empty for no limit.',
        'Cancel',
        'Add to lineup',
      ]) {
        final text = inDialog(find.text(line));
        expect(text, findsOneWidget, reason: line);
        await tester.ensureVisible(text);
        await tester.pumpAndSettle();
        final rect = tester.getRect(text);
        final box = tester.getRect(dialog);
        // Inside the dialog's width, and on screen where it fits one: the
        // long title, in the test's square glyphs, is taller than the window,
        // and scrolls with the rest.
        expect(rect.left, greaterThanOrEqualTo(box.left), reason: line);
        expect(rect.right, lessThanOrEqualTo(box.right), reason: line);
        if (rect.height <= window.height) {
          expect(window.intersect(rect), rect, reason: line);
          expect(box.intersect(rect), rect, reason: line);
        }
        // Every line of it laid out, none cut off.
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: text, matching: find.byType(RichText)).first,
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: line);
        expect(
          paragraph.size.height,
          paragraph.getMaxIntrinsicHeight(paragraph.size.width),
          reason: line,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the dialog is named for its game, and each choice says '
        'which is chosen', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, scopes: [wholeEvent, onFriday]);

      expect(
        find.bySemanticsLabel('Add Catan to the lineup'),
        findsWidgets,
      );
      expect(
        tester.getSemantics(scope(null)),
        isSemantics(
          label: 'For the whole event',
          isChecked: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(role(ScheduledGameRole.primary)),
        isSemantics(label: 'Primary', isSelected: true),
      );
      expect(
        tester.getSemantics(role(ScheduledGameRole.filler)),
        isSemantics(label: 'Filler', isSelected: false),
      );

      // A Filler's minutes say what they are as the field takes focus.
      await choose(tester, role(ScheduledGameRole.filler));
      expect(
        tester.getSemantics(
          find.descendant(of: minutes, matching: find.byType(EditableText)),
        ),
        isSemantics(
          isTextField: true,
          label: 'Minutes',
          hint: 'The longest it should run. Leave it empty for no limit.',
        ),
      );
      handle.dispose();
    });
  });
}
