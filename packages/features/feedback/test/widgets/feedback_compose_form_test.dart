import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// Pins the #107 compose widget: severity is hidden (not merely inert)
/// for feature requests, an invalid submit surfaces the localized
/// required errors without invoking the callback, and a valid submit
/// hands up the trimmed [FeedbackComposeResult]. All copy resolves from
/// [FeedbackLocalizations] (assertions match the English template).
void main() {
  late FeedbackComposeFormModel model;

  setUp(() => model = FeedbackComposeFormModel());
  tearDown(() => model.dispose());

  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: FeedbackLocalizations.localizationsDelegates,
    supportedLocales: FeedbackLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  /// The form and its button, as the host composes them. The host pins the
  /// button as a page footer (#211); here it only has to be present.
  Widget compose({
    ValueChanged<FeedbackComposeResult>? onSubmit,
    bool enabled = true,
  }) => Column(
    children: [
      FeedbackComposeForm(
        model: model,
        onSubmit: onSubmit ?? (_) {},
        enabled: enabled,
      ),
      FeedbackComposeSubmitButton(
        model: model,
        onSubmit: onSubmit ?? (_) {},
        enabled: enabled,
      ),
    ],
  );

  Future<void> pick(WidgetTester tester, Key field, String option) async {
    await tester.ensureVisible(find.byKey(field));
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    // The selected value and the open menu can both render the label;
    // the menu entry is the last hit.
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('renders category, severity (bug default), message, title, '
      'and the review affordance', (tester) async {
    await tester.pumpWidget(wrap(compose()));

    expect(find.byKey(FeedbackComposeForm.categoryFieldKey), findsOneWidget);
    expect(find.byKey(FeedbackComposeForm.severityFieldKey), findsOneWidget);
    expect(find.byKey(FeedbackComposeForm.messageFieldKey), findsOneWidget);
    expect(find.byKey(FeedbackComposeForm.titleFieldKey), findsOneWidget);
    expect(find.text('Review report'), findsOneWidget);
  });

  testWidgets('selecting feature request hides the severity field; '
      'selecting bug restores it', (tester) async {
    await tester.pumpWidget(wrap(compose()));

    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Feature request');
    expect(find.byKey(FeedbackComposeForm.severityFieldKey), findsNothing);

    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Bug');
    expect(find.byKey(FeedbackComposeForm.severityFieldKey), findsOneWidget);
  });

  testWidgets('an invalid submit surfaces required errors and does not '
      'invoke the callback', (tester) async {
    FeedbackComposeResult? submitted;
    await tester.pumpWidget(wrap(compose(onSubmit: (r) => submitted = r)));

    await tester.ensureVisible(
      find.byKey(FeedbackComposeSubmitButton.buttonKey),
    );
    await tester.tap(find.byKey(FeedbackComposeSubmitButton.buttonKey));
    await tester.pump();

    expect(submitted, isNull);
    expect(
      find.text('This field is required.'),
      findsWidgets,
      reason: 'message and severity are both required for a bug',
    );
  });

  testWidgets('an invalid submit moves focus to the first invalid control, '
      'the severity dropdown', (tester) async {
    await tester.pumpWidget(wrap(compose()));

    await tester.ensureVisible(
      find.byKey(FeedbackComposeSubmitButton.buttonKey),
    );
    await tester.tap(find.byKey(FeedbackComposeSubmitButton.buttonKey));
    await tester.pumpAndSettle();

    // #230. Category is seeded, so severity is the first control a bug report
    // is missing. Asserted through the focused element's ancestry, because a
    // dropdown has no EditableText to ask.
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find.ancestor(
        of: find.byElementPredicate((element) => element == focused),
        matching: find.byKey(FeedbackComposeForm.severityFieldKey),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a valid bug submit hands up the trimmed result', (tester) async {
    FeedbackComposeResult? submitted;
    await tester.pumpWidget(wrap(compose(onSubmit: (r) => submitted = r)));

    await pick(tester, FeedbackComposeForm.severityFieldKey, 'High');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      '  it broke  ',
    );
    await tester.enterText(
      find.byKey(FeedbackComposeForm.titleFieldKey),
      'Crash on save',
    );
    await tester.ensureVisible(
      find.byKey(FeedbackComposeSubmitButton.buttonKey),
    );
    await tester.tap(find.byKey(FeedbackComposeSubmitButton.buttonKey));
    await tester.pump();

    expect(
      submitted,
      const FeedbackComposeResult(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.high,
        message: 'it broke',
        title: 'Crash on save',
      ),
    );
  });

  testWidgets("the title field's done action submits the form", (tester) async {
    // The button moved to the host's footer (#211); the keyboard path stayed
    // with the form, and takes the same validation.
    FeedbackComposeResult? submitted;
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (r) => submitted = r)),
    );

    await pick(tester, FeedbackComposeForm.severityFieldKey, 'Low');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      'it broke',
    );
    await tester.showKeyboard(find.byKey(FeedbackComposeForm.titleFieldKey));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(
      submitted,
      const FeedbackComposeResult(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'it broke',
      ),
    );
  });

  testWidgets('a valid feature-request submit needs no severity and '
      'carries none', (tester) async {
    FeedbackComposeResult? submitted;
    await tester.pumpWidget(wrap(compose(onSubmit: (r) => submitted = r)));

    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Feature request');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      'please add dice',
    );
    await tester.ensureVisible(
      find.byKey(FeedbackComposeSubmitButton.buttonKey),
    );
    await tester.tap(find.byKey(FeedbackComposeSubmitButton.buttonKey));
    await tester.pump();

    expect(
      submitted,
      const FeedbackComposeResult(
        category: FeedbackCategory.featureRequest,
        message: 'please add dice',
      ),
    );
  });

  testWidgets('severity is selectable again after a feature-request '
      'submit round trip', (tester) async {
    await tester.pumpWidget(wrap(compose()));

    // A feature-request validation disables the severity control…
    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Feature request');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      'please add dice',
    );
    await tester.ensureVisible(
      find.byKey(FeedbackComposeSubmitButton.buttonKey),
    );
    await tester.tap(find.byKey(FeedbackComposeSubmitButton.buttonKey));
    await tester.pump();

    // …and switching back to bug must re-enable it on sight.
    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Bug');
    await pick(tester, FeedbackComposeForm.severityFieldKey, 'Medium');

    expect(
      model.form.control(FeedbackComposeFormModel.severityControlName).value,
      FeedbackSeverity.medium,
    );
  });

  testWidgets('enabled: false disables the review affordance', (tester) async {
    await tester.pumpWidget(wrap(compose(enabled: false)));

    final button = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(FeedbackComposeSubmitButton.buttonKey),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
