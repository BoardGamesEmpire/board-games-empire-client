import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';

/// Pins the #40 create-household form: labelled (never hint-only) fields,
/// required-after-trim name validation surfacing the localized message
/// without invoking the callback, the trimmed hand-off, and the disabled +
/// progress submit state. All copy resolves from [HouseholdLocalizations]
/// (assertions match the English template).
///
/// The `accessibility` group is #132: it asserts the *semantics tree* and
/// the real IME action paths rather than rendered text and widget
/// properties, because "labelled, focus order, keyboard submit" are claims
/// about what assistive tech and a keyboard actually get.
void main() {
  Widget wrap(Widget child, {TextScaler textScaler = TextScaler.noScaling}) =>
      MaterialApp(
        localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
        supportedLocales: HouseholdLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      );

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(CreateHouseholdForm.submitButtonKey));
    await tester.tap(find.byKey(CreateHouseholdForm.submitButtonKey));
    await tester.pump();
  }

  /// The `EditableText` under a field key — the widget that owns the focus
  /// node and the platform input connection.
  Finder editableOf(Key fieldKey) => find.descendant(
    of: find.byKey(fieldKey),
    matching: find.byType(EditableText),
  );

  bool hasFocus(WidgetTester tester, Key fieldKey) =>
      tester.widget<EditableText>(editableOf(fieldKey)).focusNode.hasFocus;

  /// The [TextField] the reactive field actually builds, so decoration and
  /// read-only state are asserted against what the framework receives.
  TextField textFieldOf(WidgetTester tester, Key fieldKey) =>
      tester.widget<TextField>(
        find.descendant(
          of: find.byKey(fieldKey),
          matching: find.byType(TextField),
        ),
      );

  group('CreateHouseholdForm', () {
    testWidgets('renders labelled name and description fields and a submit '
        'button (labels, never hint-only)', (tester) async {
      await tester.pumpWidget(
        wrap(CreateHouseholdForm(onSubmit: ({required name, description}) {})),
      );

      expect(find.text('Household name'), findsOneWidget);
      expect(find.text('Description (optional)'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Create household'),
        findsOneWidget,
      );
    });

    testWidgets('a blank name surfaces the localized required error and does '
        'not invoke the callback', (tester) async {
      var called = false;
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            onSubmit: ({required name, description}) => called = true,
          ),
        ),
      );

      await submit(tester);

      expect(called, isFalse);
      expect(find.text('Enter a name for your household.'), findsOneWidget);
    });

    testWidgets('a whitespace-only name is rejected the same way', (
      tester,
    ) async {
      var called = false;
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            onSubmit: ({required name, description}) => called = true,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(CreateHouseholdForm.nameFieldKey),
        '   ',
      );
      await submit(tester);

      expect(
        called,
        isFalse,
        reason: 'validity must match the trimmed hand-off value',
      );
      expect(find.text('Enter a name for your household.'), findsOneWidget);
    });

    testWidgets('a valid submit hands up the trimmed name and a null '
        'description when blank', (tester) async {
      String? submittedName;
      String? submittedDescription;
      var called = false;
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            onSubmit: ({required name, description}) {
              called = true;
              submittedName = name;
              submittedDescription = description;
            },
          ),
        ),
      );

      await tester.enterText(
        find.byKey(CreateHouseholdForm.nameFieldKey),
        '  Game Night HQ  ',
      );
      await submit(tester);

      expect(called, isTrue);
      expect(submittedName, 'Game Night HQ');
      expect(submittedDescription, isNull);
    });

    testWidgets('a whitespace-only description hands up null', (tester) async {
      String? submittedDescription = 'sentinel';
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            onSubmit: ({required name, description}) =>
                submittedDescription = description,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(CreateHouseholdForm.nameFieldKey),
        'HQ',
      );
      await tester.enterText(
        find.byKey(CreateHouseholdForm.descriptionFieldKey),
        '   ',
      );
      await submit(tester);

      expect(submittedDescription, isNull);
    });

    testWidgets('a description is trimmed and handed up', (tester) async {
      String? submittedDescription;
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            onSubmit: ({required name, description}) =>
                submittedDescription = description,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(CreateHouseholdForm.nameFieldKey),
        'HQ',
      );
      await tester.enterText(
        find.byKey(CreateHouseholdForm.descriptionFieldKey),
        '  Where we play  ',
      );
      await submit(tester);

      expect(submittedDescription, 'Where we play');
    });

    testWidgets('while submitting the button is disabled (not hidden) and '
        'shows a spinner', (tester) async {
      var called = false;
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            submitting: true,
            onSubmit: ({required name, description}) => called = true,
          ),
        ),
      );

      final button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(CreateHouseholdForm.submitButtonKey),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull, reason: 'disabled, but still present');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Create household'), findsNothing);

      await submit(tester);
      expect(called, isFalse);
    });
  });

  group('CreateHouseholdForm accessibility (#132)', () {
    testWidgets('both fields are labelled through their decoration rather '
        'than leaning on a hint', (tester) async {
      await tester.pumpWidget(
        wrap(CreateHouseholdForm(onSubmit: ({required name, description}) {})),
      );

      // A hint may be added later; what must never happen is a hint
      // standing in for the label, so the label is what is pinned.
      expect(
        textFieldOf(tester, CreateHouseholdForm.nameFieldKey).decoration,
        isA<InputDecoration>().having(
          (d) => d.labelText,
          'labelText',
          'Household name',
        ),
      );
      expect(
        textFieldOf(tester, CreateHouseholdForm.descriptionFieldKey).decoration,
        isA<InputDecoration>().having(
          (d) => d.labelText,
          'labelText',
          'Description (optional)',
        ),
      );
    });

    testWidgets('both fields reach the semantics tree as labelled text '
        'fields', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        wrap(CreateHouseholdForm(onSubmit: ({required name, description}) {})),
      );

      // Scoped to each field's own subtree so a label cannot be satisfied
      // by some unrelated node, and matched with a RegExp so the assertion
      // survives semantics merging (a merged node's label is the
      // concatenation of its children's).
      for (final (fieldKey, label) in <(Key, String)>[
        (CreateHouseholdForm.nameFieldKey, 'Household name'),
        (CreateHouseholdForm.descriptionFieldKey, 'Description'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(fieldKey),
            matching: find.bySemanticsLabel(RegExp(label)),
          ),
          findsAtLeastNWidgets(1),
          reason: '$label must be exposed to assistive tech',
        );
        expect(
          tester.getSemantics(editableOf(fieldKey)),
          isSemantics(isTextField: true),
        );
      }

      // Dispose inline, not via addTearDown: flutter_test verifies that no
      // SemanticsHandle is outstanding at the end of the test body, which runs
      // before tearDown callbacks.
      handle.dispose();
    });

    testWidgets('the keyboard "next" action moves focus from the name field '
        'to the description field', (tester) async {
      await tester.pumpWidget(
        wrap(CreateHouseholdForm(onSubmit: ({required name, description}) {})),
      );

      // enterText focuses the field and attaches the platform input
      // connection, which is what receiveAction dispatches to.
      await tester.enterText(
        find.byKey(CreateHouseholdForm.nameFieldKey),
        'Game Night HQ',
      );
      expect(hasFocus(tester, CreateHouseholdForm.nameFieldKey), isTrue);

      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();

      expect(
        hasFocus(tester, CreateHouseholdForm.descriptionFieldKey),
        isTrue,
        reason: 'focus order must be name -> description',
      );
      expect(hasFocus(tester, CreateHouseholdForm.nameFieldKey), isFalse);
    });

    testWidgets('the keyboard "done" action on the description submits with '
        'the same trimmed hand-off as the button', (tester) async {
      String? submittedName;
      String? submittedDescription;
      var called = false;
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            onSubmit: ({required name, description}) {
              called = true;
              submittedName = name;
              submittedDescription = description;
            },
          ),
        ),
      );

      await tester.enterText(
        find.byKey(CreateHouseholdForm.nameFieldKey),
        '  Game Night HQ  ',
      );
      await tester.enterText(
        find.byKey(CreateHouseholdForm.descriptionFieldKey),
        '  Where we play  ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(called, isTrue, reason: 'submit must be reachable by keyboard');
      expect(submittedName, 'Game Night HQ');
      expect(submittedDescription, 'Where we play');
    });

    testWidgets('the in-flight button keeps an accessible name and announces '
        'itself instead of leaving a bare spinner', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            submitting: true,
            onSubmit: ({required name, description}) {},
          ),
        ),
      );

      // The regression this guards: a disabled button whose only child is a
      // spinner has no accessible name, so a screen reader announces
      // nothing at the moment the user most needs status.
      expect(
        find.widgetWithText(FilledButton, 'Creating household…'),
        findsOneWidget,
      );
      // Matched by ancestry of the progress label rather than by position:
      // FilledButton contributes its own Semantics, so "the first
      // Semantics under the button" is not ours.
      expect(
        find.ancestor(
          of: find.text('Creating household…'),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && (w.properties.liveRegion ?? false),
          ),
        ),
        findsOneWidget,
        reason: 'the state change must be announced, not just exposed',
      );

      // Asserted on the semantics node, not the widget tree: the regression
      // guarded is a disabled button with no accessible name, which is a
      // property of the node the platform sees, not of which widgets happen
      // to be nested where.
      expect(
        tester.getSemantics(
          find.descendant(
            of: find.byKey(CreateHouseholdForm.submitButtonKey),
            matching: find.byType(FilledButton),
          ),
        ),
        isSemantics(
          label: 'Creating household…',
          isButton: true,
          isLiveRegion: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );

      handle.dispose();
    });

    testWidgets('while submitting both fields are read-only, closing the '
        'keyboard submit path', (tester) async {
      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            submitting: true,
            onSubmit: ({required name, description}) {},
          ),
        ),
      );

      // Read-only tears down the input connection, so there is no IME
      // action to guard in the first place — and values captured at submit
      // cannot drift out from under the in-flight request.
      expect(
        textFieldOf(tester, CreateHouseholdForm.nameFieldKey).readOnly,
        isTrue,
      );
      expect(
        textFieldOf(tester, CreateHouseholdForm.descriptionFieldKey).readOnly,
        isTrue,
      );
    });

    testWidgets('the in-flight button does not overflow on a narrow screen '
        'at large text scale', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(
          CreateHouseholdForm(
            submitting: true,
            onSubmit: ({required name, description}) {},
          ),
          textScaler: const TextScaler.linear(2),
        ),
      );

      // 320dp with the OS large-text setting is a small phone belonging to
      // precisely the user this label was added for; a RenderFlex overflow
      // there would be worse than the bare spinner it replaced.
      expect(tester.takeException(), isNull);
      expect(
        find.widgetWithText(FilledButton, 'Creating household…'),
        findsOneWidget,
      );
    });
  });
}
