import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';

/// Pins the #40 create-household form: labelled (never hint-only) fields,
/// required-after-trim name validation surfacing the localized message
/// without invoking the callback, the trimmed hand-off, and the disabled +
/// spinner submit state. All copy resolves from [HouseholdLocalizations]
/// (assertions match the English template).
void main() {
  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(CreateHouseholdForm.submitButtonKey));
    await tester.tap(find.byKey(CreateHouseholdForm.submitButtonKey));
    await tester.pump();
  }

  group('CreateHouseholdForm', () {
    testWidgets('renders labelled name and description fields and a submit '
        'button (labels, never hint-only)', (tester) async {
      await tester.pumpWidget(
        wrap(CreateHouseholdForm(onSubmit: ({required name, description}) {})),
      );

      expect(find.text('Household name'), findsOneWidget);
      expect(find.text('Description (optional)'), findsOneWidget);
      expect(
        find.widgetWithText(ElevatedButton, 'Create household'),
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

      final button = tester.widget<ElevatedButton>(
        find.byKey(CreateHouseholdForm.submitButtonKey),
      );
      expect(button.onPressed, isNull, reason: 'disabled, but still present');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Create household'), findsNothing);

      await submit(tester);
      expect(called, isFalse);
    });
  });
}
