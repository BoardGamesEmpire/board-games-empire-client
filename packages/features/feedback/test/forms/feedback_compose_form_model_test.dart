import 'package:feedback/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// Pins the #107 compose form rules: category defaults to bug with
/// severity required; feature requests exclude severity from validity
/// (disabled, value preserved); submission validation touches everything
/// on failure; the hand-off value is trimmed and normalized.
void main() {
  late FeedbackComposeFormModel model;

  setUp(() => model = FeedbackComposeFormModel());
  tearDown(() => model.dispose());

  void setCategory(FeedbackCategory category) =>
      model.form.control(FeedbackComposeFormModel.categoryControlName).value =
          category;
  void setSeverity(FeedbackSeverity severity) =>
      model.form.control(FeedbackComposeFormModel.severityControlName).value =
          severity;
  void setMessage(String message) =>
      model.form.control(FeedbackComposeFormModel.messageControlName).value =
          message;
  void setTitle(String title) =>
      model.form.control(FeedbackComposeFormModel.titleControlName).value =
          title;

  group('initial state', () {
    test('defaults to bug with severity applicable and required', () {
      expect(model.category, FeedbackCategory.bug);
      expect(model.severityApplicable, isTrue);
      expect(model.form.valid, isFalse, reason: 'message + severity missing');
    });

    test('a bug is not submittable without a severity', () {
      setMessage('it broke');
      expect(model.form.valid, isFalse);

      setSeverity(FeedbackSeverity.high);
      expect(model.form.valid, isTrue);
    });
  });

  group('conditional severity', () {
    test('feature request excludes severity from validity', () {
      setCategory(FeedbackCategory.featureRequest);
      expect(model.severityApplicable, isFalse);

      setMessage('please add dice');
      expect(
        model.validateForSubmit(),
        isTrue,
        reason: 'severity must not block a feature-request submission',
      );
    });

    test('switching back to bug re-enables severity with the prior value '
        'preserved', () {
      setSeverity(FeedbackSeverity.medium);
      setCategory(FeedbackCategory.featureRequest);
      expect(model.severityApplicable, isFalse);

      setCategory(FeedbackCategory.bug);
      expect(model.severityApplicable, isTrue);
      expect(
        model.form.control(FeedbackComposeFormModel.severityControlName).value,
        FeedbackSeverity.medium,
        reason: 'a category round trip must not discard the choice',
      );
    });
  });

  group('validateForSubmit', () {
    test('returns false and touches every control when invalid', () {
      expect(model.validateForSubmit(), isFalse);
      expect(
        model.form.control(FeedbackComposeFormModel.messageControlName).touched,
        isTrue,
      );
      expect(
        model.form
            .control(FeedbackComposeFormModel.severityControlName)
            .touched,
        isTrue,
      );
    });

    test('returns true when valid', () {
      setSeverity(FeedbackSeverity.low);
      setMessage('it broke');
      expect(model.validateForSubmit(), isTrue);
    });
  });

  group('buildResult', () {
    test('trims message and title and carries severity for bugs', () {
      setSeverity(FeedbackSeverity.critical);
      setMessage('  it broke  ');
      setTitle('  Crash on save  ');

      expect(
        model.buildResult(),
        const FeedbackComposeResult(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.critical,
          message: 'it broke',
          title: 'Crash on save',
        ),
      );
    });

    test('normalizes a blank title to null', () {
      setSeverity(FeedbackSeverity.low);
      setMessage('it broke');
      setTitle('   ');

      expect(model.buildResult().title, isNull);
    });

    test('drops severity for feature requests even when a value was '
        'picked earlier', () {
      setSeverity(FeedbackSeverity.high);
      setCategory(FeedbackCategory.featureRequest);
      setMessage('please add dice');

      expect(
        model.buildResult(),
        const FeedbackComposeResult(
          category: FeedbackCategory.featureRequest,
          message: 'please add dice',
        ),
      );
    });
  });
}
