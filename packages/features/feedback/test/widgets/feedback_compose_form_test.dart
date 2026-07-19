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
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (_) {})),
    );

    expect(find.byKey(FeedbackComposeForm.categoryFieldKey), findsOneWidget);
    expect(find.byKey(FeedbackComposeForm.severityFieldKey), findsOneWidget);
    expect(find.byKey(FeedbackComposeForm.messageFieldKey), findsOneWidget);
    expect(find.byKey(FeedbackComposeForm.titleFieldKey), findsOneWidget);
    expect(find.text('Review report'), findsOneWidget);
  });

  testWidgets('selecting feature request hides the severity field; '
      'selecting bug restores it', (tester) async {
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (_) {})),
    );

    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Feature request');
    expect(find.byKey(FeedbackComposeForm.severityFieldKey), findsNothing);

    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Bug');
    expect(find.byKey(FeedbackComposeForm.severityFieldKey), findsOneWidget);
  });

  testWidgets('an invalid submit surfaces required errors and does not '
      'invoke the callback', (tester) async {
    FeedbackComposeResult? submitted;
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (r) => submitted = r)),
    );

    await tester.ensureVisible(find.byKey(FeedbackComposeForm.submitButtonKey));
    await tester.tap(find.byKey(FeedbackComposeForm.submitButtonKey));
    await tester.pump();

    expect(submitted, isNull);
    expect(
      find.text('This field is required.'),
      findsWidgets,
      reason: 'message and severity are both required for a bug',
    );
  });

  testWidgets('a valid bug submit hands up the trimmed result', (tester) async {
    FeedbackComposeResult? submitted;
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (r) => submitted = r)),
    );

    await pick(tester, FeedbackComposeForm.severityFieldKey, 'High');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      '  it broke  ',
    );
    await tester.enterText(
      find.byKey(FeedbackComposeForm.titleFieldKey),
      'Crash on save',
    );
    await tester.ensureVisible(find.byKey(FeedbackComposeForm.submitButtonKey));
    await tester.tap(find.byKey(FeedbackComposeForm.submitButtonKey));
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

  testWidgets('a valid feature-request submit needs no severity and '
      'carries none', (tester) async {
    FeedbackComposeResult? submitted;
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (r) => submitted = r)),
    );

    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Feature request');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      'please add dice',
    );
    await tester.ensureVisible(find.byKey(FeedbackComposeForm.submitButtonKey));
    await tester.tap(find.byKey(FeedbackComposeForm.submitButtonKey));
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
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (_) {})),
    );

    // A feature-request validation disables the severity control…
    await pick(tester, FeedbackComposeForm.categoryFieldKey, 'Feature request');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      'please add dice',
    );
    await tester.ensureVisible(find.byKey(FeedbackComposeForm.submitButtonKey));
    await tester.tap(find.byKey(FeedbackComposeForm.submitButtonKey));
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
    await tester.pumpWidget(
      wrap(FeedbackComposeForm(model: model, onSubmit: (_) {}, enabled: false)),
    );

    final button = tester.widget<FilledButton>(
      find.byKey(FeedbackComposeForm.submitButtonKey),
    );
    expect(button.onPressed, isNull);
  });
}
