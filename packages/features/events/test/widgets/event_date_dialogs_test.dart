import 'package:bge_test_support/widgets.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_date_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

const _confirmedNote = "Attendees aren't told when a confirmed date changes.";
const _tooLong = 'Keep the reason to 1,000 characters or fewer.';

/// What a dialog popped with, once it has.
class _Popped<T> {
  bool done = false;
  T? value;

  void complete(T result) {
    done = true;
    value = result;
  }
}

/// The date dialogs (#506): add and edit, and what each hands back; confirm,
/// with its offer to decline the others (#507), decline, cancel and remove;
/// and each one at 320dp and 2.0 text.
void main() {
  // Local, as the pickers give it: Monday 26 October 2026, 6 PM.
  final now = DateTime(2026, 10, 26, 18);

  /// A Confirmed date as the server sends it, in UTC, with each field set.
  final opening = confirmed(
    'o-1',
    DateTime.utc(2026, 11, 7, 1, 30),
    end: DateTime.utc(2026, 11, 7, 5),
    location: 'The back room',
  ).copyWith(label: 'Opening night');

  /// Opens the dialog [show] shows, from a button, and records what it pops
  /// with.
  Future<_Popped<T>> open<T>(
    WidgetTester tester,
    Future<T> Function(BuildContext context) show, {
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    final popped = _Popped<T>();
    // A new app, not the last one's navigator with its dialog still up.
    await tester.pumpWidget(const SizedBox());
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
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => show(context).then(popped.complete),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return popped;
  }

  /// Picks [day] of October in the date picker [field] opens, then types
  /// [hour] and [minute] into the time picker. An evening time: the picker
  /// opens on one, so its period is already PM.
  Future<void> pick(
    WidgetTester tester,
    Key field, {
    required int day,
    required int hour,
    int minute = 0,
  }) async {
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.tap(find.text('$day'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to text input mode'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '$hour');
    await tester.enterText(fields.at(1), '$minute'.padLeft(2, '0'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byKey(EventDateDialogKeys.submit));
    await tester.pumpAndSettle();
  }

  VoidCallback? submitOf(WidgetTester tester) => tester
      .widget<ButtonStyleButton>(find.byKey(EventDateDialogKeys.submit))
      .onPressed;

  group('add', () {
    testWidgets('add needs a start, and refuses an end before it', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 800));
      final popped = await open(
        tester,
        (context) => showAddDateDialog(context, now: () => now),
      );
      expect(find.text('Add a date'), findsOneWidget);

      await submit(tester);
      expect(find.text('Pick when it starts.'), findsOneWidget);
      expect(popped.done, isFalse);

      await pick(
        tester,
        EventDateDialogKeys.start,
        day: 28,
        hour: 7,
        minute: 30,
      );
      await pick(tester, EventDateDialogKeys.end, day: 28, hour: 6);
      expect(find.text('Pick when it starts.'), findsNothing);
      expect(find.text('Ends before it starts.'), findsOneWidget);

      await submit(tester);
      expect(popped.done, isFalse);

      await tester.tap(find.byKey(EventDateDialogKeys.clearEnd));
      await tester.pump();
      await submit(tester);

      expect(popped.done, isTrue);
      expect(
        popped.value,
        EventOccurrenceDraft(startDate: DateTime(2026, 10, 28, 19, 30).toUtc()),
      );
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('add returns the draft, with blank fields as null', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 800));
      var popped = await open(
        tester,
        (context) => showAddDateDialog(context, now: () => now),
      );
      await tester.enterText(find.byKey(EventDateDialogKeys.label), '   ');
      await tester.enterText(find.byKey(EventDateDialogKeys.location), '   ');
      await pick(
        tester,
        EventDateDialogKeys.start,
        day: 28,
        hour: 7,
        minute: 30,
      );
      await pick(tester, EventDateDialogKeys.end, day: 28, hour: 11);
      await submit(tester);

      // Times go out in UTC, as the create form's do.
      expect(
        popped.value,
        EventOccurrenceDraft(
          startDate: DateTime(2026, 10, 28, 19, 30).toUtc(),
          endDate: DateTime(2026, 10, 28, 23).toUtc(),
        ),
      );

      // The add is sent as given, so the dialog trims.
      popped = await open(
        tester,
        (context) => showAddDateDialog(context, now: () => now),
      );
      await tester.enterText(find.byKey(EventDateDialogKeys.label), ' Day 2 ');
      await tester.enterText(
        find.byKey(EventDateDialogKeys.location),
        '  The back room ',
      );
      await pick(
        tester,
        EventDateDialogKeys.start,
        day: 28,
        hour: 7,
        minute: 30,
      );
      await submit(tester);

      expect(
        popped.value,
        EventOccurrenceDraft(
          label: 'Day 2',
          startDate: DateTime(2026, 10, 28, 19, 30).toUtc(),
          location: 'The back room',
        ),
      );
    });

    testWidgets('discarding returns nothing', (tester) async {
      final popped = await open(
        tester,
        (context) => showAddDateDialog(context, now: () => now),
      );
      await tester.enterText(find.byKey(EventDateDialogKeys.label), 'Day 2');
      expect(find.text('Discard'), findsOneWidget);

      await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
      await tester.pumpAndSettle();

      expect(popped.done, isTrue);
      expect(popped.value, isNull);
    });
  });

  group('edit', () {
    testWidgets("edit's Save is disabled until something changes", (
      tester,
    ) async {
      final popped = await open(
        tester,
        (context) => showEditDateDialog(context, opening, now: () => now),
      );
      expect(find.text('Edit Opening night'), findsOneWidget);
      expect(find.text('Opening night'), findsOneWidget);
      expect(find.text('The back room'), findsOneWidget);
      // The form holds the times in local time, and the date in UTC: the
      // same moments, so no change.
      expect(find.text('Save'), findsOneWidget);
      expect(submitOf(tester), isNull);

      // Trimmed, as it would be sent: whitespace alone changes nothing.
      await tester.enterText(
        find.byKey(EventDateDialogKeys.label),
        '  Opening night ',
      );
      await tester.pump();
      expect(submitOf(tester), isNull);

      await tester.enterText(
        find.byKey(EventDateDialogKeys.label),
        'Opening night, moved',
      );
      await tester.pump();
      expect(submitOf(tester), isNotNull);

      // Back as it was.
      await tester.enterText(
        find.byKey(EventDateDialogKeys.label),
        'Opening night',
      );
      await tester.pump();
      expect(submitOf(tester), isNull);

      await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
      await tester.pumpAndSettle();
      expect(popped.done, isTrue);
      expect(popped.value, isNull);
    });

    testWidgets('edit returns only what changed, and a cleared venue as '
        'clearLocation', (tester) async {
      var popped = await open(
        tester,
        (context) => showEditDateDialog(context, opening, now: () => now),
      );
      await tester.enterText(find.byKey(EventDateDialogKeys.location), '  ');
      await tester.pump();
      await submit(tester);

      // `"location": null` and nothing else (#506).
      expect(popped.value, OccurrenceUpdate(clearLocation: true));

      popped = await open(
        tester,
        (context) => showEditDateDialog(context, opening, now: () => now),
      );
      await tester.tap(find.byKey(EventDateDialogKeys.clearEnd));
      await tester.pump();
      await tester.enterText(find.byKey(EventDateDialogKeys.label), ' Day 1 ');
      await tester.pump();
      await submit(tester);

      expect(
        popped.value,
        OccurrenceUpdate(label: 'Day 1', clearEndDate: true),
      );
    });

    testWidgets('edit sends a picked start in UTC, and nothing else', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 800));
      final proposal = opening.copyWith(
        status: OccurrenceStatus.proposed,
        startDate: DateTime(2026, 10, 28, 19).toUtc(),
        endDate: null,
      );
      final popped = await open(
        tester,
        (context) => showEditDateDialog(context, proposal, now: () => now),
      );

      await pick(tester, EventDateDialogKeys.start, day: 28, hour: 8);
      await submit(tester);

      expect(
        popped.value,
        OccurrenceUpdate(startDate: DateTime(2026, 10, 28, 20).toUtc()),
      );
    });

    testWidgets('a date already past keeps its day when edited', (
      tester,
    ) async {
      // Yesterday evening, local: Sunday 25 October, 7 PM. An ongoing
      // event's first day, say, whose end is being fixed.
      useViewSize(tester, const Size(400, 800));
      final yesterday = opening.copyWith(
        startDate: DateTime(2026, 10, 25, 19).toUtc(),
        endDate: null,
      );
      final popped = await open(
        tester,
        (context) => showEditDateDialog(context, yesterday, now: () => now),
      );

      await pick(tester, EventDateDialogKeys.start, day: 25, hour: 8);
      await pick(tester, EventDateDialogKeys.end, day: 25, hour: 11);
      await submit(tester);

      expect(
        popped.value,
        OccurrenceUpdate(
          startDate: DateTime(2026, 10, 25, 20).toUtc(),
          endDate: DateTime(2026, 10, 25, 23).toUtc(),
        ),
      );
    });

    testWidgets('a date past the calendar keeps its day when edited', (
      tester,
    ) async {
      // Wednesday 7 November 2029, 7 PM local: past the two years the
      // calendar runs to.
      useViewSize(tester, const Size(400, 800));
      final distant = opening.copyWith(
        startDate: DateTime(2029, 11, 7, 19).toUtc(),
        endDate: null,
      );
      final popped = await open(
        tester,
        (context) => showEditDateDialog(context, distant, now: () => now),
      );

      await pick(tester, EventDateDialogKeys.start, day: 7, hour: 8);
      await pick(tester, EventDateDialogKeys.end, day: 7, hour: 11);
      await submit(tester);

      expect(
        popped.value,
        OccurrenceUpdate(
          startDate: DateTime(2029, 11, 7, 20).toUtc(),
          endDate: DateTime(2029, 11, 7, 23).toUtc(),
        ),
      );
    });

    testWidgets('a date with no start is renamed without picking one', (
      tester,
    ) async {
      // A poll's date can have none, which the server takes.
      final unscheduled = opening.copyWith(
        status: OccurrenceStatus.proposed,
        startDate: null,
        endDate: null,
      );
      final popped = await open(
        tester,
        (context) => showEditDateDialog(context, unscheduled, now: () => now),
      );

      await tester.enterText(find.byKey(EventDateDialogKeys.label), 'Day 2');
      await tester.pump();
      await submit(tester);

      expect(popped.value, OccurrenceUpdate(label: 'Day 2'));
    });

    testWidgets('editing a confirmed date shows the note', (tester) async {
      await open(
        tester,
        (context) => showEditDateDialog(context, opening, now: () => now),
      );
      expect(find.text(_confirmedNote), findsOneWidget);

      await open(
        tester,
        (context) => showEditDateDialog(
          context,
          opening.copyWith(status: OccurrenceStatus.proposed),
          now: () => now,
        ),
      );
      expect(find.text('Edit Opening night'), findsOneWidget);
      expect(find.text(_confirmedNote), findsNothing);
    });
  });

  group('cancel', () {
    Future<_Popped<String?>> openCancel(
      WidgetTester tester, {
      bool removing = false,
    }) => open(
      tester,
      (context) =>
          showCancelDateDialog(context, 'Opening night', removing: removing),
    );

    Future<void> reason(WidgetTester tester, String text) =>
        tester.enterText(find.byKey(EventDateDialogKeys.reason), text);

    testWidgets("cancel's reason is trimmed, blank is '', and 1001 characters "
        'is refused in the field', (tester) async {
      var popped = await openCancel(tester);
      expect(find.text('Cancel Opening night?'), findsOneWidget);
      expect(
        find.text(
          "Everyone who answered this date is told. It can't be confirmed "
          'again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Reason (optional)'), findsOneWidget);

      await reason(tester, 'a' * 1001);
      await submit(tester);
      expect(find.text(_tooLong), findsOneWidget);
      expect(popped.done, isFalse);

      // The server counts it trimmed, as the remote does.
      await reason(tester, ' ${'a' * 1000} ');
      await submit(tester);
      expect(popped.value, 'a' * 1000);

      popped = await openCancel(tester);
      await reason(tester, '  The venue flooded.  ');
      await submit(tester);
      expect(popped.value, 'The venue flooded.');

      // The server counts code points, so an emoji is one character, not
      // two.
      popped = await openCancel(tester);
      await reason(tester, '🎲' * 1000);
      await submit(tester);
      expect(popped.value, '🎲' * 1000);

      // Spaces alone are no reason (#506).
      popped = await openCancel(tester);
      await reason(tester, '   ');
      await submit(tester);
      expect(popped.done, isTrue);
      expect(popped.value, '');

      popped = await openCancel(tester);
      await submit(tester);
      expect(popped.value, '');
    });

    testWidgets('cancel kept returns null', (tester) async {
      final popped = await openCancel(tester);
      await reason(tester, 'The venue flooded.');
      expect(find.text('Keep date'), findsOneWidget);

      await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
      await tester.pumpAndSettle();

      expect(popped.done, isTrue);
      expect(popped.value, isNull);
    });

    testWidgets('cancelling to remove says it does both', (tester) async {
      final popped = await openCancel(tester, removing: true);

      expect(find.text('Remove Opening night?'), findsOneWidget);
      expect(
        find.text(
          "It's cancelled first, so everyone who answered is told, then "
          "removed. This can't be undone.",
        ),
        findsOneWidget,
      );
      expect(find.text('Reason (optional)'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);

      await reason(tester, 'The venue flooded.');
      await submit(tester);
      expect(popped.value, 'The venue flooded.');
    });
  });

  group('confirm', () {
    const body =
        'A confirmed date can be cancelled, but not set back to proposed.';
    const declineOthers = 'Also decline the other proposed dates';
    const declinedForGood = "A declined date can't be proposed again.";

    Future<_Popped<({bool declineOthers})?>> openConfirm(
      WidgetTester tester, {
      bool? offerDeclineOthers,
    }) => open(
      tester,
      (context) => offerDeclineOthers == null
          ? showConfirmDateDialog(context, 'Opening night')
          : showConfirmDateDialog(
              context,
              'Opening night',
              offerDeclineOthers: offerDeclineOthers,
            ),
    );

    Finder checkbox() => find.byKey(EventDateDialogKeys.declineOthers);

    testWidgets('confirm asks, and answers whether to go ahead', (
      tester,
    ) async {
      var popped = await openConfirm(tester);
      expect(find.text('Confirm Opening night?'), findsOneWidget);
      expect(find.text(body), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);
      await submit(tester);
      expect(popped.value, (declineOthers: false));

      popped = await openConfirm(tester);
      await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
      await tester.pumpAndSettle();
      expect(popped.done, isTrue);
      expect(popped.value, isNull);
    });

    testWidgets('confirm offers decline the others only when asked, off by '
        'default', (tester) async {
      await openConfirm(tester);
      expect(checkbox(), findsNothing);
      expect(find.text(declineOthers), findsNothing);

      await openConfirm(tester, offerDeclineOthers: false);
      expect(checkbox(), findsNothing);

      await openConfirm(tester, offerDeclineOthers: true);
      expect(checkbox(), findsOneWidget);
      expect(find.text(declineOthers), findsOneWidget);
      expect(find.text(body), findsOneWidget);
      // Off: a declined date can't be proposed again, as the box says.
      expect(
        find.descendant(of: checkbox(), matching: find.text(declinedForGood)),
        findsOneWidget,
      );
      // One control, which says both.
      expect(
        tester.getSemantics(checkbox()),
        isSemantics(
          label: '$declineOthers\n$declinedForGood',
          hasCheckedState: true,
          isChecked: false,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
    });

    testWidgets('confirm returns declineOthers when checked, and null when '
        'kept', (tester) async {
      var popped = await openConfirm(tester, offerDeclineOthers: true);
      await tester.tap(checkbox());
      await tester.pumpAndSettle();
      expect(tester.getSemantics(checkbox()), isSemantics(isChecked: true));
      await submit(tester);
      expect(popped.value, (declineOthers: true));

      // Checked, then unchecked.
      popped = await openConfirm(tester, offerDeclineOthers: true);
      await tester.tap(checkbox());
      await tester.pumpAndSettle();
      await tester.tap(checkbox());
      await tester.pumpAndSettle();
      await submit(tester);
      expect(popped.value, (declineOthers: false));

      // Kept, checked or not, is null.
      popped = await openConfirm(tester, offerDeclineOthers: true);
      await tester.tap(checkbox());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
      await tester.pumpAndSettle();
      expect(popped.done, isTrue);
      expect(popped.value, isNull);
    });
  });

  testWidgets('decline and remove ask, and answer whether to go ahead', (
    tester,
  ) async {
    final dialogs = {
      'Decline': (
        show: showDeclineDateDialog,
        title: 'Decline Opening night?',
        body: "A declined date can't be proposed again.",
      ),
      'Remove': (
        show: showRemoveDateDialog,
        title: 'Remove Opening night?',
        body: "This can't be undone.",
      ),
    };

    for (final MapEntry(key: action, value: dialog) in dialogs.entries) {
      var popped = await open(
        tester,
        (context) => dialog.show(context, 'Opening night'),
      );
      expect(find.text(dialog.title), findsOneWidget, reason: action);
      expect(find.text(dialog.body), findsOneWidget, reason: action);
      expect(find.text(action), findsOneWidget, reason: action);
      await submit(tester);
      expect(popped.value, isTrue, reason: action);

      popped = await open(
        tester,
        (context) => dialog.show(context, 'Opening night'),
      );
      await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
      await tester.pumpAndSettle();
      expect(popped.value, isFalse, reason: action);
    }
  });

  group('at 320dp and 2.0 text', () {
    const name =
        'The first and longest evening of the whole tournament, with the '
        'final';
    final long = opening.copyWith(label: name);
    final dialogs = <String, Future<Object?> Function(BuildContext context)>{
      'add': (context) => showAddDateDialog(context, now: () => now),
      'edit': (context) => showEditDateDialog(context, long, now: () => now),
      'confirm': (context) => showConfirmDateDialog(context, name),
      'confirm, offering to decline the others': (context) =>
          showConfirmDateDialog(context, name, offerDeclineOthers: true),
      'decline': (context) => showDeclineDateDialog(context, name),
      'cancel': (context) =>
          showCancelDateDialog(context, name, removing: false),
      'cancel to remove': (context) =>
          showCancelDateDialog(context, name, removing: true),
      'remove': (context) => showRemoveDateDialog(context, name),
    };

    for (final MapEntry(key: dialog, value: show) in dialogs.entries) {
      testWidgets('$dialog keeps its buttons on screen and tappable', (
        tester,
      ) async {
        useViewSize(tester, const Size(320, 640));
        final popped = await open(
          tester,
          show,
          textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
        );

        expect(tester.takeException(), isNull);
        const window = Rect.fromLTWH(0, 0, 320, 640);
        for (final key in [
          EventDateDialogKeys.submit,
          EventDateDialogKeys.dismiss,
        ]) {
          final rect = tester.getRect(find.byKey(key));
          expect(window.intersect(rect), rect, reason: '$key');
          expect(find.byKey(key).hitTestable(), findsOneWidget, reason: '$key');
        }
        // The checkbox is in the dialog's scroll, and reached by scrolling.
        // Its box, that is: with the warning under it, the whole tile can
        // be taller than the screen at this size.
        final checkbox = find.descendant(
          of: find.byKey(EventDateDialogKeys.declineOthers),
          matching: find.byType(Checkbox),
        );
        if (checkbox.evaluate().isNotEmpty) {
          await tester.ensureVisible(checkbox);
          await tester.pumpAndSettle();
          final rect = tester.getRect(checkbox);
          expect(window.intersect(rect), rect);
          expect(checkbox.hitTestable(), findsOneWidget);
        }

        await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
        await tester.pumpAndSettle();
        expect(popped.done, isTrue);
      });
    }
  });
}
