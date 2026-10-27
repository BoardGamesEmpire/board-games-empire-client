import 'package:bge_test_support/widgets.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/create/event_rules_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Pins the create form's *Advanced: rules* (#499): how games get added,
/// and for a vote, how it is decided and for how long; what [policyOf] sends
/// for them; and the section that edits them.
void main() {
  FormControl<GameAdditionMode> gameAdditionOf(FormGroup form) =>
      form.control(EventCreateControls.gameAddition)
          as FormControl<GameAdditionMode>;
  FormControl<VoteThresholdType> thresholdOf(FormGroup form) =>
      form.control(EventCreateControls.threshold)
          as FormControl<VoteThresholdType>;
  FormControl<String> thresholdValueOf(FormGroup form) =>
      form.control(EventCreateControls.thresholdValue) as FormControl<String>;
  FormControl<VoteQuorumType> quorumOf(FormGroup form) =>
      form.control(EventCreateControls.quorum) as FormControl<VoteQuorumType>;
  FormControl<String> quorumValueOf(FormGroup form) =>
      form.control(EventCreateControls.quorumValue) as FormControl<String>;
  FormControl<String> windowOf(FormGroup form) =>
      form.control(EventCreateControls.windowHours) as FormControl<String>;

  /// A form whose other sections are filled in, so that its rules alone
  /// decide whether it is valid.
  FormGroup validForm() {
    final form = buildEventCreateForm();
    form.control(EventCreateControls.title).value = 'Game night';
    final dates = form.control(
      EventCreateControls.dates,
    ) as FormArray<Map<String, Object?>>;
    (dates.controls.first as FormGroup)
        .control(EventCreateControls.start)
        .value = DateTime(
      2026,
      11,
      14,
      19,
    );
    return form;
  }

  /// [form], voting on games with [threshold] and [quorum].
  FormGroup votingWith(
    FormGroup form, {
    VoteThresholdType threshold = VoteThresholdType.simpleMajority,
    VoteQuorumType quorum = VoteQuorumType.none,
  }) {
    gameAdditionOf(form).value = GameAdditionMode.requiresVote;
    thresholdOf(form).value = threshold;
    quorumOf(form).value = quorum;
    return form;
  }

  /// The error [control] shows for a number out of its range, or null.
  Object? rangeError(FormControl<String> control) =>
      control.errors[EventCreateErrors.wholeNumber];

  final modes = GameAdditionMode.values.where(
    (mode) => mode != GameAdditionMode.unknown,
  );
  final thresholds = VoteThresholdType.values.where(
    (type) => type != VoteThresholdType.unknown,
  );
  final quorums = VoteQuorumType.values.where(
    (type) => type != VoteQuorumType.unknown,
  );

  group('policyOf', () {
    test('untouched rules send no policy', () {
      final form = buildEventCreateForm();

      expect(gameAdditionOf(form).value, isNull);
      expect(policyOf(form), isNull);
    });

    test('Direct sends no policy', () {
      final form = buildEventCreateForm();
      gameAdditionOf(form).value = GameAdditionMode.direct;

      expect(policyOf(form), isNull);
    });

    test('Host approval sends only the mode', () {
      final form = buildEventCreateForm();
      gameAdditionOf(form).value = GameAdditionMode.hostApproval;

      expect(
        policyOf(form),
        const EventPolicyDraft(gameAdditionMode: GameAdditionMode.hostApproval),
      );

      // Hosts only, the same way.
      gameAdditionOf(form).value = GameAdditionMode.hostOnly;
      expect(
        policyOf(form),
        const EventPolicyDraft(gameAdditionMode: GameAdditionMode.hostOnly),
      );
    });

    test('a supermajority of 50 or 101 is refused', () {
      final form = votingWith(
        validForm(),
        threshold: VoteThresholdType.supermajority,
      );

      for (final number in ['50', '101']) {
        thresholdValueOf(form).value = number;

        expect(rangeError(thresholdValueOf(form)), (
          min: 51,
          max: 100,
        ), reason: number);
        expect(form.valid, isFalse, reason: number);
      }

      for (final number in ['51', '100']) {
        thresholdValueOf(form).value = number;
        expect(form.valid, isTrue, reason: number);
      }
    });

    test('a supermajority of 66 sends the type and value', () {
      final form = votingWith(
        validForm(),
        threshold: VoteThresholdType.supermajority,
      );

      // 66 is where a supermajority starts.
      expect(thresholdValueOf(form).value, '66');
      expect(form.valid, isTrue);
      expect(
        policyOf(form),
        const EventPolicyDraft(
          gameAdditionMode: GameAdditionMode.requiresVote,
          voteThresholdType: VoteThresholdType.supermajority,
          voteThresholdValue: 66,
          voteQuorumType: VoteQuorumType.none,
        ),
      );
    });

    test('an empty voting window sends none', () {
      final form = votingWith(validForm());

      for (final empty in [null, '', '   ']) {
        windowOf(form).value = empty;

        expect(form.valid, isTrue, reason: '"$empty"');
        expect(policyOf(form)!.votingWindowHours, isNull, reason: '"$empty"');
      }

      windowOf(form).value = ' 48 ';
      expect(policyOf(form)!.votingWindowHours, 48);
      windowOf(form).value = '0';
      expect(rangeError(windowOf(form)), (min: 1, max: null));
      expect(form.valid, isFalse);
    });

    test('only a whole number is taken', () {
      final form = votingWith(
        validForm(),
        threshold: VoteThresholdType.fixedCount,
        quorum: VoteQuorumType.percentOfAttendees,
      );

      for (final number in ['', 'three', '2.5', '-3', '+3', '1e2', '0x10']) {
        thresholdValueOf(form).value = number;
        expect(rangeError(thresholdValueOf(form)), (
          min: 1,
          max: null,
        ), reason: '"$number"');
      }
      for (final number in ['0', '101', ' ']) {
        quorumValueOf(form).value = number;
        expect(rangeError(quorumValueOf(form)), (
          min: 1,
          max: 100,
        ), reason: '"$number"');
      }

      thresholdValueOf(form).value = ' 12 ';
      quorumValueOf(form).value = '1';
      expect(form.valid, isTrue);
      expect(policyOf(form)!.voteThresholdValue, 12);
      expect(policyOf(form)!.voteQuorumValue, 1);
    });

    test('a number past what the server can store is refused', () {
      // The server keeps these in a Postgres integer.
      final form = votingWith(
        validForm(),
        threshold: VoteThresholdType.fixedCount,
      );

      for (final control in [thresholdValueOf(form), windowOf(form)]) {
        control.value = '2147483647';
        expect(control.errors, isEmpty);

        for (final number in ['2147483648', '99999999999999999999999']) {
          control.value = number;
          expect(rangeError(control), (
            min: 1,
            max: 2147483647,
          ), reason: number);
        }
        control.value = '3';
      }
    });

    test('switching a type starts its number over', () {
      final form = votingWith(validForm());
      final value = thresholdValueOf(form);

      // Simple majority takes no number.
      expect(value.disabled, isTrue);
      thresholdOf(form).value = VoteThresholdType.supermajority;
      expect((value.value, value.enabled), ('66', true));
      value.value = '75';
      thresholdOf(form).value = VoteThresholdType.fixedCount;
      expect((value.value, value.enabled), ('3', true));
      thresholdOf(form).value = VoteThresholdType.unanimous;
      expect((value.value, value.disabled), (null, true));

      // A number refused for one type is checked again for the next.
      thresholdOf(form).value = VoteThresholdType.supermajority;
      value.value = '3';
      expect(value.valid, isFalse);
      thresholdOf(form).value = VoteThresholdType.fixedCount;
      expect((value.value, value.valid), ('3', true));

      // Set to the type it has, nothing starts over: a whole form's value
      // set or reset sets every control, changed or not.
      value.value = '7';
      thresholdOf(form).value = VoteThresholdType.fixedCount;
      expect(value.value, '7');

      final quorumValue = quorumValueOf(form);
      expect(quorumValue.disabled, isTrue);
      quorumOf(form).value = VoteQuorumType.percentOfAttendees;
      expect((quorumValue.value, quorumValue.enabled), ('50', true));
      quorumOf(form).value = VoteQuorumType.fixedCount;
      expect((quorumValue.value, quorumValue.enabled), ('3', true));
      quorumOf(form).value = VoteQuorumType.none;
      expect((quorumValue.value, quorumValue.disabled), (null, true));
    });

    test('a bad value left behind a hidden vote setting does not block the '
        'form', () {
      final form = votingWith(
        validForm(),
        threshold: VoteThresholdType.supermajority,
        quorum: VoteQuorumType.percentOfAttendees,
      );
      thresholdValueOf(form).value = '50';
      quorumValueOf(form).value = '0';
      windowOf(form).value = 'soon';
      expect(form.valid, isFalse);

      gameAdditionOf(form).value = GameAdditionMode.hostApproval;

      // Hidden, so neither checked nor sent.
      expect(form.valid, isTrue);
      for (final control in [
        thresholdOf(form),
        thresholdValueOf(form),
        quorumOf(form),
        quorumValueOf(form),
        windowOf(form),
      ]) {
        expect(control.disabled, isTrue);
      }
      expect(
        policyOf(form),
        const EventPolicyDraft(gameAdditionMode: GameAdditionMode.hostApproval),
      );

      // Back to a vote, they are shown and checked again, as they were.
      gameAdditionOf(form).value = GameAdditionMode.requiresVote;
      expect(thresholdValueOf(form).value, '50');
      expect(rangeError(thresholdValueOf(form)), (min: 51, max: 100));
      expect(form.valid, isFalse);
    });

    test('every policy draft the form builds passes checkSendable', () {
      var walked = 0;
      for (final mode in [null, ...modes]) {
        for (final threshold in thresholds) {
          for (final quorum in quorums) {
            final form = validForm();
            gameAdditionOf(form).value = mode;
            thresholdOf(form).value = threshold;
            quorumOf(form).value = quorum;
            final combination = '$mode, $threshold, $quorum';

            expect(form.valid, isTrue, reason: combination);
            final policy = policyOf(form);
            expect(
              () =>
                  EventDraft(title: 'Game night', policy: policy)
                    ..checkSendable(),
              returnsNormally,
              reason: combination,
            );
            if (mode == GameAdditionMode.requiresVote) {
              expect(policy!.voteThresholdType, threshold);
              expect(policy.voteQuorumType, quorum);
            }
            walked++;
          }
        }
      }
      expect(walked, 5 * 4 * 3);
    });
  });

  group('EventRulesSection', () {
    late FormGroup form;

    setUp(() => form = validForm());

    Widget host({
      bool readOnly = false,
      TextScaler textScaler = TextScaler.noScaling,
      bool disableAnimations = false,
    }) => MaterialApp(
      theme: BgeTheme.light(),
      localizationsDelegates: EventsLocalizations.localizationsDelegates,
      supportedLocales: EventsLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: textScaler,
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: BgePage(
        child: ReactiveForm(
          formGroup: form,
          child: EventRulesSection(readOnly: readOnly),
        ),
      ),
    );

    Finder title() => find.text('Advanced: rules');

    Future<void> toggleRules(WidgetTester tester) async {
      await tester.ensureVisible(title());
      await tester.pumpAndSettle();
      await tester.tap(title());
      await tester.pumpAndSettle();
    }

    /// Opens the dropdown [field] and picks [option] from its menu.
    Future<void> choose(WidgetTester tester, Key field, String option) async {
      await tester.ensureVisible(find.byKey(field));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      // The menu's copy, above the field's own.
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    DropdownButton<T> dropdown<T>(WidgetTester tester) =>
        tester.widget<DropdownButton<T>>(find.byType(DropdownButton<T>));

    Finder labelled(Key field, String label) =>
        find.descendant(of: find.byKey(field), matching: find.text(label));

    /// Where the tile's header ends, and with it what the tile clips.
    double headerBottom(WidgetTester tester) => tester
        .getRect(
          find
              .descendant(
                of: find.byKey(EventRulesSection.tileKey),
                matching: find.byType(ListTile),
              )
              .first,
        )
        .bottom;

    testWidgets('the rules start collapsed', (tester) async {
      await tester.pumpWidget(host());

      expect(title(), findsOneWidget);
      expect(find.byKey(EventRulesSection.gameAdditionKey), findsNothing);

      await toggleRules(tester);

      // Untouched, it reads as the server's default, and Direct leads.
      final modes = dropdown<GameAdditionMode>(tester);
      expect(modes.value, isNull);
      expect((modes.hint! as Text).data, 'Anyone attending adds them');
      expect(modes.items!.map((item) => item.value), [
        GameAdditionMode.direct,
        GameAdditionMode.requiresVote,
        GameAdditionMode.hostApproval,
        GameAdditionMode.hostOnly,
      ]);
      expect(
        labelled(EventRulesSection.gameAdditionKey, 'How games get added'),
        findsOneWidget,
      );
    });

    testWidgets('the locked note shows while the rules are collapsed', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      const locked = "Rules can't be changed after the event is created.";
      await tester.pumpWidget(host());

      // Rules left untouched are as final as any, so it shows before they
      // are opened.
      expect(find.byKey(EventRulesSection.gameAdditionKey), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(EventRulesSection.lockedKey)).data,
        locked,
      );
      // Read with the title, as part of the form: not announced.
      expect(
        tester.getSemantics(find.byKey(EventRulesSection.lockedKey)),
        isSemantics(label: 'Advanced: rules\n$locked', isLiveRegion: false),
      );

      // Open, it shows once still.
      await toggleRules(tester);
      expect(find.text(locked), findsOneWidget);
      // With nothing above it, the first menu's label floats above the
      // menu, where the tile clips what it opens below the header.
      expect(
        tester
            .getRect(
              labelled(
                EventRulesSection.gameAdditionKey,
                'How games get added',
              ),
            )
            .top,
        greaterThanOrEqualTo(headerBottom(tester)),
      );
      semantics.dispose();
    });

    testWidgets('the rules open and close at once where the platform asks for '
        'reduced motion', (tester) async {
      await tester.pumpWidget(host(disableAnimations: true));
      final tile = find.byKey(EventRulesSection.tileKey);
      final closed = tester.getSize(tile).height;

      await tester.tap(title());
      await tester.pump();
      // Open in the frame the tap lands in, not grown over the next ones.
      final opened = tester.getSize(tile).height;
      await tester.pumpAndSettle();
      expect(tester.getSize(tile).height, opened);
      expect(opened, greaterThan(closed));

      await tester.tap(title());
      await tester.pump();
      expect(tester.getSize(tile).height, closed);
    });

    testWidgets('voting settings show only for Attendees vote', (tester) async {
      await tester.pumpWidget(host());
      await toggleRules(tester);
      final voting = [
        EventRulesSection.thresholdKey,
        EventRulesSection.quorumKey,
        EventRulesSection.windowKey,
      ];
      for (final key in voting) {
        expect(find.byKey(key), findsNothing);
      }

      await choose(tester, EventRulesSection.gameAdditionKey, 'Attendees vote');
      expect(gameAdditionOf(form).value, GameAdditionMode.requiresVote);
      for (final key in voting) {
        expect(find.byKey(key), findsOneWidget);
      }
      // More than half, and no turnout needed: no number for either.
      expect(find.byKey(EventRulesSection.thresholdValueKey), findsNothing);
      expect(find.byKey(EventRulesSection.quorumValueKey), findsNothing);
      expect(
        labelled(EventRulesSection.thresholdKey, 'More than half'),
        findsWidgets,
      );
      expect(find.text('Leave empty to close voting yourself'), findsOneWidget);

      for (final mode in [
        'The host approves them',
        'Only hosts add them',
        'Anyone attending adds them',
      ]) {
        await choose(tester, EventRulesSection.gameAdditionKey, mode);
        for (final key in voting) {
          expect(find.byKey(key), findsNothing, reason: mode);
        }
      }
    });

    testWidgets("a type's number starts at its default", (tester) async {
      await tester.pumpWidget(host());
      await toggleRules(tester);
      await choose(tester, EventRulesSection.gameAdditionKey, 'Attendees vote');

      await choose(tester, EventRulesSection.thresholdKey, 'A set share');
      expect(
        labelled(EventRulesSection.thresholdValueKey, 'Share (%)'),
        findsOneWidget,
      );
      expect(
        labelled(EventRulesSection.thresholdValueKey, '66'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(EventRulesSection.thresholdValueKey),
        '75',
      );

      await choose(tester, EventRulesSection.thresholdKey, 'A set number');
      expect(
        labelled(EventRulesSection.thresholdValueKey, 'Number of votes'),
        findsOneWidget,
      );
      expect(thresholdValueOf(form).value, '3');
      await tester.enterText(
        find.byKey(EventRulesSection.thresholdValueKey),
        '7',
      );
      // Choosing the type already chosen starts nothing over.
      await choose(tester, EventRulesSection.thresholdKey, 'A set number');
      expect(thresholdValueOf(form).value, '7');

      await choose(tester, EventRulesSection.quorumKey, 'A share of attendees');
      expect(
        labelled(EventRulesSection.quorumValueKey, 'Share of attendees (%)'),
        findsOneWidget,
      );
      expect(quorumValueOf(form).value, '50');
      await choose(tester, EventRulesSection.quorumKey, 'A set number');
      expect(
        labelled(EventRulesSection.quorumValueKey, 'Number of voters'),
        findsOneWidget,
      );
      expect(quorumValueOf(form).value, '3');
      await choose(tester, EventRulesSection.quorumKey, 'None');
      expect(find.byKey(EventRulesSection.quorumValueKey), findsNothing);
    });

    testWidgets('a rule with an error keeps the rules open', (tester) async {
      votingWith(form, threshold: VoteThresholdType.supermajority);
      await tester.pumpWidget(host());
      await toggleRules(tester);
      await tester.enterText(
        find.byKey(EventRulesSection.thresholdValueKey),
        '50',
      );
      await tester.pump();

      await toggleRules(tester);

      // Still open, saying what is wrong.
      expect(find.byKey(EventRulesSection.thresholdValueKey), findsOneWidget);
      expect(find.text('Enter a whole number from 51 to 100.'), findsOneWidget);

      // Fixed, the rules close.
      await tester.enterText(
        find.byKey(EventRulesSection.thresholdValueKey),
        '60',
      );
      await toggleRules(tester);
      expect(find.byKey(EventRulesSection.thresholdValueKey), findsNothing);
    });

    testWidgets('a refused submit goes to a rule with an error', (
      tester,
    ) async {
      votingWith(form);
      windowOf(form).value = '0';
      await tester.pumpWidget(host());
      await toggleRules(tester);

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(windowOf(form).hasFocus, isTrue);
      expect(find.text('Enter a whole number of at least 1.'), findsOneWidget);
    });

    testWidgets('a read-only section changes nothing', (tester) async {
      votingWith(
        form,
        threshold: VoteThresholdType.supermajority,
        quorum: VoteQuorumType.fixedCount,
      );
      await tester.pumpWidget(host(readOnly: true));

      // The rules still open, to be read.
      await toggleRules(tester);
      expect(find.byKey(EventRulesSection.thresholdValueKey), findsOneWidget);

      await tester.tap(find.byKey(EventRulesSection.gameAdditionKey));
      await tester.pumpAndSettle();
      // No menu opened: the choices not picked are nowhere on screen.
      expect(find.text('The host approves them'), findsNothing);
      expect(gameAdditionOf(form).value, GameAdditionMode.requiresVote);
      expect(dropdown<GameAdditionMode>(tester).onChanged, isNull);
      expect(dropdown<VoteThresholdType>(tester).onChanged, isNull);
      expect(dropdown<VoteQuorumType>(tester).onChanged, isNull);
      for (final key in [
        EventRulesSection.thresholdValueKey,
        EventRulesSection.quorumValueKey,
        EventRulesSection.windowKey,
      ]) {
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(TextField),
          ),
        );
        expect(field.readOnly, isTrue, reason: '$key');
      }
      // Locked by readOnly, not by disabling: no control was disabled.
      expect(thresholdValueOf(form).enabled, isTrue);
      expect(quorumValueOf(form).enabled, isTrue);
    });

    testWidgets('the rules fit at 320dp wide at 2.0 text scale', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 568));
      votingWith(
        form,
        threshold: VoteThresholdType.supermajority,
        quorum: VoteQuorumType.percentOfAttendees,
      );
      thresholdValueOf(form).value = '50';
      quorumValueOf(form).value = '0';
      windowOf(form).value = '0';
      await tester.pumpWidget(
        host(textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor)),
      );
      await toggleRules(tester);
      // Every error showing, as after a refused submit.
      form.markAllAsTouched();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Enter a whole number from 51 to 100.'), findsOneWidget);
      // The first menu's label, at its largest, clear of the tile's clip.
      expect(
        tester
            .getRect(
              labelled(
                EventRulesSection.gameAdditionKey,
                'How games get added',
              ),
            )
            .top,
        greaterThanOrEqualTo(headerBottom(tester)),
      );
      // A menu's choice wraps whole: a dense field would squeeze it into
      // one line's height, which throws nothing.
      for (final (key, choice) in [
        (EventRulesSection.gameAdditionKey, 'Attendees vote'),
        (EventRulesSection.thresholdKey, 'A set share'),
        (EventRulesSection.quorumKey, 'A share of attendees'),
      ]) {
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.byKey(key), matching: find.text(choice)),
        );
        expect(
          text.size.height,
          greaterThanOrEqualTo(text.getMaxIntrinsicHeight(text.size.width)),
          reason: choice,
        );
      }

      await choose(tester, EventRulesSection.gameAdditionKey, 'Attendees vote');
      expect(tester.takeException(), isNull);
      await choose(tester, EventRulesSection.quorumKey, 'A share of attendees');
      expect(tester.takeException(), isNull);
    });
  });
}
