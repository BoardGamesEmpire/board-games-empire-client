import 'package:bge_test_support/widgets.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/create/event_create_dates_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Pins the create form's *When* (#499): the dates check each mode applies,
/// what [occurrencesOf] sends for it, and the section that edits them.
void main() {
  // Local, as the pickers give it: Monday 26 October 2026, 6 PM.
  final now = DateTime(2026, 10, 26, 18);
  DateTime day(int day, [int hour = 19]) => DateTime(2026, 11, day, hour);

  FormControl<EventSchedulingMode> modeOf(FormGroup form) =>
      form.control(EventCreateControls.mode)
          as FormControl<EventSchedulingMode>;
  FormArray<Map<String, Object?>> datesOf(FormGroup form) =>
      form.control(EventCreateControls.dates)
          as FormArray<Map<String, Object?>>;
  FormGroup rowOf(FormGroup form, int index) =>
      datesOf(form).controls[index] as FormGroup;
  FormControl<DateTime> startOf(FormGroup form, int index) =>
      rowOf(form, index).control(EventCreateControls.start)
          as FormControl<DateTime>;
  FormControl<DateTime> endOf(FormGroup form, int index) =>
      rowOf(form, index).control(EventCreateControls.end)
          as FormControl<DateTime>;
  FormControl<String> labelOf(FormGroup form, int index) =>
      rowOf(form, index).control(EventCreateControls.label)
          as FormControl<String>;

  /// A new form with its title filled in, so that its dates alone decide
  /// whether it is valid.
  FormGroup titled() =>
      buildEventCreateForm()
        ..control(EventCreateControls.title).value = 'Game night';

  /// A form in [mode] whose rows start at [starts], in order.
  FormGroup formWith(EventSchedulingMode mode, List<DateTime?> starts) {
    final form = titled();
    for (var n = 1; n < starts.length; n++) {
      datesOf(form).add(buildEventDateRow());
    }
    for (final (index, start) in starts.indexed) {
      startOf(form, index).value = start;
    }
    modeOf(form).value = mode;
    return form;
  }

  group('the dates check', () {
    test('one date needs a start', () {
      final form = titled();

      expect(modeOf(form).value, EventSchedulingMode.fixed);
      expect(datesOf(form).controls, hasLength(1));
      expect(form.valid, isFalse);
      expect(startOf(form, 0).hasError(ValidationMessage.required), isTrue);

      // The error clears once its cause is fixed.
      startOf(form, 0).value = day(2);
      expect(startOf(form, 0).errors, isEmpty);
      expect(form.valid, isTrue);
    });

    test('several days and a poll need at least two dates', () {
      for (final mode in [
        EventSchedulingMode.multiDay,
        EventSchedulingMode.poll,
      ]) {
        final form = formWith(mode, [day(2)]);

        expect(form.valid, isFalse, reason: '$mode with one date');
        // The form's own error, and on the mode, where it is shown.
        expect(form.errors, containsPair(EventCreateErrors.tooFewDates, true));
        expect(modeOf(form).hasError(EventCreateErrors.tooFewDates), isTrue);

        datesOf(form).add(buildEventDateRow());
        expect(modeOf(form).errors, isEmpty, reason: '$mode with two rows');
        expect(
          startOf(form, 1).hasError(ValidationMessage.required),
          isTrue,
          reason: 'each $mode date needs a start',
        );
        expect(form.valid, isFalse);

        startOf(form, 1).value = day(3);
        expect(form.valid, isTrue, reason: '$mode with two dates');
      }
    });

    test('an end before its start is refused on that row', () {
      final form = formWith(EventSchedulingMode.multiDay, [day(2), day(3)]);

      endOf(form, 1).value = day(3, 18);

      expect(endOf(form, 1).hasError(EventCreateErrors.endBeforeStart), isTrue);
      expect(endOf(form, 0).errors, isEmpty);
      expect(startOf(form, 1).errors, isEmpty);
      expect(form.valid, isFalse);

      // Fixed from the other side: the start moves before the end.
      startOf(form, 1).value = day(3, 17);
      expect(endOf(form, 1).errors, isEmpty);
      expect(form.valid, isTrue);

      // One date checks its row the same way.
      final fixed = formWith(EventSchedulingMode.fixed, [day(2)]);
      endOf(fixed, 0).value = day(2, 18);
      expect(
        endOf(fixed, 0).hasError(EventCreateErrors.endBeforeStart),
        isTrue,
      );
      endOf(fixed, 0).value = day(2, 22);
      expect(fixed.valid, isTrue);
    });

    test("a hidden row's bad end does not block one date", () {
      final form = formWith(EventSchedulingMode.multiDay, [
        day(2),
        day(3),
        null,
      ]);
      endOf(form, 1).value = day(3, 18);
      expect(form.valid, isFalse);

      // One date shows and sends only the first row: the others' errors go.
      modeOf(form).value = EventSchedulingMode.fixed;
      expect(endOf(form, 1).errors, isEmpty);
      expect(startOf(form, 2).errors, isEmpty);
      expect(form.valid, isTrue);

      // Back in several days, every row is checked again.
      modeOf(form).value = EventSchedulingMode.multiDay;
      expect(endOf(form, 1).hasError(EventCreateErrors.endBeforeStart), isTrue);
      expect(startOf(form, 2).hasError(ValidationMessage.required), isTrue);
      expect(form.valid, isFalse);
    });
  });

  group('occurrencesOf', () {
    test('switching to one date sends only the first and keeps the rest', () {
      final starts = [day(2), day(3), day(4)];
      final form = formWith(EventSchedulingMode.multiDay, starts);
      expect(occurrencesOf(form), hasLength(3));

      modeOf(form).value = EventSchedulingMode.fixed;
      final one = occurrencesOf(form);
      expect(one, hasLength(1));
      expect(one.single.startDate, day(2).toUtc());
      expect(datesOf(form).controls, hasLength(3));

      modeOf(form).value = EventSchedulingMode.multiDay;
      expect(occurrencesOf(form).map((o) => o.startDate), [
        for (final start in starts) start.toUtc(),
      ]);
    });

    test('dates go out in UTC, in row order', () {
      // Rows out of date order stay in row order: a row's position is its
      // sortOrder.
      final form = formWith(EventSchedulingMode.poll, [day(9), day(2)]);
      endOf(form, 0).value = day(9, 23);

      final sent = occurrencesOf(form);

      expect(sent.map((o) => o.startDate), [day(9).toUtc(), day(2).toUtc()]);
      expect(sent.first.endDate, day(9, 23).toUtc());
      expect(sent.last.endDate, isNull);
      expect(
        [
          for (final o in sent) ...[?o.startDate, ?o.endDate],
        ].every((d) => d.isUtc),
        isTrue,
      );
    });

    test('a label is sent for several days only, trimmed, empty as none', () {
      final form = formWith(EventSchedulingMode.multiDay, [
        day(2),
        day(3),
        day(4),
      ]);
      labelOf(form, 0).value = '  Day 1  ';
      labelOf(form, 1).value = '   ';

      expect(occurrencesOf(form).map((o) => o.label), ['Day 1', null, null]);

      // Hidden in a poll and in one date, so not sent there.
      modeOf(form).value = EventSchedulingMode.poll;
      expect(occurrencesOf(form).map((o) => o.label), [null, null, null]);
      modeOf(form).value = EventSchedulingMode.fixed;
      expect(occurrencesOf(form).single.label, isNull);
    });
  });

  group('EventCreateDatesSection', () {
    late FormGroup form;

    setUp(() => form = titled());

    Widget host({
      bool readOnly = false,
      TextScaler textScaler = TextScaler.noScaling,
      Widget? after,
    }) => MaterialApp(
      theme: BgeTheme.light(),
      localizationsDelegates: EventsLocalizations.localizationsDelegates,
      supportedLocales: EventsLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: BgePage(
        child: ReactiveForm(
          formGroup: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              EventCreateDatesSection(readOnly: readOnly, now: () => now),
              ?after,
            ],
          ),
        ),
      ),
    );

    Future<void> chooseMode(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump();
    }

    testWidgets('each mode shows its own parts', (tester) async {
      await tester.pumpWidget(host());

      // One date: one row, no labels, nothing to add.
      expect(find.byKey(EventCreateDatesSection.startKey(0)), findsOneWidget);
      expect(find.byKey(EventCreateDatesSection.labelKey(0)), findsNothing);
      expect(find.byKey(EventCreateDatesSection.addDateKey), findsNothing);
      expect(find.byKey(EventCreateDatesSection.pollHintKey), findsNothing);

      await chooseMode(tester, 'Several days');
      expect(modeOf(form).value, EventSchedulingMode.multiDay);
      expect(find.byKey(EventCreateDatesSection.labelKey(0)), findsOneWidget);
      expect(find.byKey(EventCreateDatesSection.addDateKey), findsOneWidget);
      expect(find.byKey(EventCreateDatesSection.pollHintKey), findsNothing);

      await chooseMode(tester, 'Poll');
      expect(modeOf(form).value, EventSchedulingMode.poll);
      expect(find.byKey(EventCreateDatesSection.labelKey(0)), findsNothing);
      expect(find.byKey(EventCreateDatesSection.addDateKey), findsOneWidget);
      expect(
        find.text('Propose dates. Invitees say which work for them.'),
        findsOneWidget,
      );
    });

    testWidgets('add and remove a date', (tester) async {
      await tester.pumpWidget(host());
      await chooseMode(tester, 'Several days');
      // Remove is hidden on the last row.
      expect(find.byKey(EventCreateDatesSection.removeKey(0)), findsNothing);

      await tester.tap(find.byKey(EventCreateDatesSection.addDateKey));
      await tester.pump();
      expect(datesOf(form).controls, hasLength(2));
      expect(find.byKey(EventCreateDatesSection.startKey(1)), findsOneWidget);
      expect(find.byKey(EventCreateDatesSection.removeKey(0)), findsOneWidget);
      expect(find.byKey(EventCreateDatesSection.removeKey(1)), findsOneWidget);

      startOf(form, 0).value = day(2);
      startOf(form, 1).value = day(3);
      endOf(form, 1).value = day(3, 23);
      labelOf(form, 1).value = 'Day 2';
      final kept = rowOf(form, 1);
      await tester.pump();

      await tester.tap(find.byKey(EventCreateDatesSection.removeKey(0)));
      await tester.pump();

      expect(datesOf(form).controls, [kept]);
      expect(startOf(form, 0).value, day(3));
      expect(endOf(form, 0).value, day(3, 23));
      expect(labelOf(form, 0).value, 'Day 2');
      expect(find.byKey(EventCreateDatesSection.startKey(1)), findsNothing);
      expect(find.byKey(EventCreateDatesSection.removeKey(0)), findsNothing);
    });

    testWidgets('remove buttons follow the rows the mode shows', (
      tester,
    ) async {
      datesOf(form).add(buildEventDateRow());
      modeOf(form).value = EventSchedulingMode.poll;
      await tester.pumpWidget(host());
      expect(find.byKey(EventCreateDatesSection.removeKey(0)), findsOneWidget);

      // One date shows its first row only, with nothing to remove.
      await chooseMode(tester, 'One date');
      expect(find.byKey(EventCreateDatesSection.startKey(0)), findsOneWidget);
      expect(find.byKey(EventCreateDatesSection.startKey(1)), findsNothing);
      expect(find.byKey(EventCreateDatesSection.removeKey(0)), findsNothing);
      expect(datesOf(form).controls, hasLength(2));
    });

    testWidgets('picking a start sets the row', (tester) async {
      useViewSize(tester, const Size(400, 800));
      await tester.pumpWidget(host());

      await tester.tap(find.byKey(EventCreateDatesSection.startKey(0)));
      await tester.pumpAndSettle();
      // The calendar opens on today.
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      await tester.tap(find.text('28'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Then the time, typed rather than dialled.
      await tester.tap(find.byTooltip('Switch to text input mode'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '7');
      await tester.enterText(fields.at(1), '30');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(startOf(form, 0).value, DateTime(2026, 10, 28, 19, 30));
      expect(find.text('Wed, Oct 28 · 7:30 PM'), findsOneWidget);
      expect(form.valid, isTrue);
    });

    testWidgets('cancelling either picker leaves the row as it was', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 800));
      startOf(form, 0).value = day(2);
      await tester.pumpWidget(host());

      await tester.tap(find.byKey(EventCreateDatesSection.startKey(0)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(startOf(form, 0).value, day(2));

      await tester.tap(find.byKey(EventCreateDatesSection.startKey(0)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('28'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(startOf(form, 0).value, day(2));
      expect(startOf(form, 0).touched, isFalse);
    });

    testWidgets('an end opens on its start', (tester) async {
      useViewSize(tester, const Size(400, 800));
      startOf(form, 0).value = DateTime(2026, 11, 14, 19, 30);
      await tester.pumpWidget(host());

      await tester.tap(find.byKey(EventCreateDatesSection.endKey(0)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(endOf(form, 0).value, DateTime(2026, 11, 14, 19, 30));
    });

    testWidgets('a set end can be cleared', (tester) async {
      startOf(form, 0).value = day(2);
      await tester.pumpWidget(host());
      expect(find.byKey(EventCreateDatesSection.clearEndKey(0)), findsNothing);

      endOf(form, 0).value = day(2, 23);
      await tester.pump();
      expect(find.byTooltip('Clear the end time'), findsOneWidget);

      await tester.tap(find.byKey(EventCreateDatesSection.clearEndKey(0)));
      await tester.pump();

      expect(endOf(form, 0).value, isNull);
      expect(startOf(form, 0).value, day(2));
      expect(find.byKey(EventCreateDatesSection.clearEndKey(0)), findsNothing);
    });

    testWidgets('a refused submit shows each date error on its row', (
      tester,
    ) async {
      await tester.pumpWidget(host());

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(find.text('Pick when it starts.'), findsOneWidget);
      expect(startOf(form, 0).hasFocus, isTrue);

      startOf(form, 0).value = day(2);
      endOf(form, 0).value = day(2, 18);
      await tester.pumpAndSettle();
      expect(find.text('Pick when it starts.'), findsNothing);
      expect(find.text('Ends before it starts.'), findsOneWidget);
    });

    testWidgets('a focused picker field draws focused', (tester) async {
      final scheme = BgeTheme.light().colorScheme;
      InputDecorator decoratorOf(Key field) => tester.widget<InputDecorator>(
        find.descendant(
          of: find.byKey(field),
          matching: find.byType(InputDecorator),
        ),
      );
      final start = find.byKey(EventCreateDatesSection.startKey(0));
      await tester.pumpWidget(host());
      expect(
        decoratorOf(EventCreateDatesSection.startKey(0)).isFocused,
        isFalse,
      );
      expect(start, isNot(paints..path(color: scheme.primary)));

      // Focused as a refused submit or the keyboard focuses it, it draws the
      // theme's focused border, as a text field does.
      startOf(form, 0).focus();
      await tester.pump();
      expect(
        decoratorOf(EventCreateDatesSection.startKey(0)).isFocused,
        isTrue,
      );
      // The decorator moves from one border to the other over a few frames.
      await tester.pumpAndSettle();
      expect(
        start,
        paints..path(
          color: scheme.primary,
          strokeWidth: BgeTokens.standard.focusOutlineWidth,
        ),
      );
      expect(decoratorOf(EventCreateDatesSection.endKey(0)).isFocused, isFalse);

      // And is drawn again as the focus moves on.
      endOf(form, 0).focus();
      await tester.pumpAndSettle();
      expect(
        decoratorOf(EventCreateDatesSection.startKey(0)).isFocused,
        isFalse,
      );
      expect(decoratorOf(EventCreateDatesSection.endKey(0)).isFocused, isTrue);
    });

    testWidgets('a read-only picker field is no button', (tester) async {
      final semantics = tester.ensureSemantics();
      final start = find.byKey(EventCreateDatesSection.startKey(0));
      await tester.pumpWidget(host());
      expect(
        tester.getSemantics(start),
        isSemantics(label: 'Starts', isButton: true, hasTapAction: true),
      );

      // While a create is on its way there is nothing to press, so it only
      // says what it holds, as a read-only text field does.
      await tester.pumpWidget(host(readOnly: true));
      expect(
        tester.getSemantics(start),
        isSemantics(label: 'Starts', isButton: false, hasTapAction: false),
      );
      semantics.dispose();
    });

    testWidgets('a refused submit with too few dates goes to Add a date', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 600));
      startOf(form, 0).value = day(2);
      modeOf(form).value = EventSchedulingMode.poll;
      // The rest of the form, below: the submit is at its end.
      await tester.pumpWidget(host(after: const SizedBox(height: 3000)));
      await tester.drag(find.byType(Scrollable), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(
        find.byKey(EventCreateDatesSection.addDateKey).hitTestable(),
        findsNothing,
      );

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(find.text('Add at least two dates.'), findsOneWidget);
      expect(modeOf(form).hasFocus, isTrue);
      expect(
        find.byKey(EventCreateDatesSection.addDateKey).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.text('Add at least two dates.').hitTestable(),
        findsOneWidget,
      );

      await tester.tap(find.byKey(EventCreateDatesSection.addDateKey));
      await tester.pump();
      expect(find.text('Add at least two dates.'), findsNothing);
    });

    testWidgets('a read-only section changes nothing', (tester) async {
      useViewSize(tester, const Size(400, 1200));
      datesOf(form).add(buildEventDateRow());
      startOf(form, 0).value = day(2);
      endOf(form, 0).value = day(2, 23);
      modeOf(form).value = EventSchedulingMode.multiDay;
      await tester.pumpWidget(host(readOnly: true));

      await tester.tap(find.text('Poll'));
      await tester.tap(find.byKey(EventCreateDatesSection.startKey(0)));
      await tester.tap(find.byKey(EventCreateDatesSection.addDateKey));
      await tester.tap(find.byKey(EventCreateDatesSection.removeKey(1)));
      await tester.tap(find.byKey(EventCreateDatesSection.clearEndKey(0)));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(modeOf(form).value, EventSchedulingMode.multiDay);
      expect(datesOf(form).controls, hasLength(2));
      expect(startOf(form, 0).value, day(2));
      expect(endOf(form, 0).value, day(2, 23));
      final label = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(EventCreateDatesSection.labelKey(0)),
          matching: find.byType(TextField),
        ),
      );
      expect(label.readOnly, isTrue);
    });

    testWidgets('the pickers fit at 320dp wide at 2.0 text scale', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 568));
      datesOf(form).add(buildEventDateRow());
      endOf(form, 1).value = day(3, 23);
      modeOf(form).value = EventSchedulingMode.multiDay;
      await tester.pumpWidget(
        host(textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor)),
      );
      // Every error showing, as after a refused submit.
      form.rejectSubmit();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(
        find.byKey(EventCreateDatesSection.startKey(0)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EventCreateDatesSection.startKey(0)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // At this scale the calendar's days no longer fit their cells, so the
      // date is typed, with the calendar a tap away.
      expect(find.byType(InputDatePickerFormField), findsOneWidget);
      expect(find.byType(CalendarDatePicker), findsNothing);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(startOf(form, 0).value, now);
    });
  });
}
