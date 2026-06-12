import 'package:observability/observability.dart';
import 'package:test/test.dart';

FeedbackReport _report() => FeedbackReport(
  category: FeedbackCategory.bug,
  severity: FeedbackSeverity.high,
  message: 'crash on add-to-collection',
  title: 'Add crash',
  appVersion: '0.1.0',
  platform: 'android',
  locale: 'en-US',
  deviceInfo: const {'model': 'Pixel 9', 'osVersion': '16'},
);

void main() {
  group('FeedbackReportPreview.isRedactable', () {
    test('accepts the redactable top-level string fields', () {
      final preview = FeedbackReportPreview(report: _report());
      for (final field in const [
        'title',
        'message',
        'appVersion',
        'platform',
        'locale',
      ]) {
        expect(preview.isRedactable(field), isTrue, reason: field);
      }
    });

    test('accepts deviceInfo dot-paths', () {
      final preview = FeedbackReportPreview(report: _report());
      expect(preview.isRedactable('deviceInfo.model'), isTrue);
    });

    test('rejects structural and unknown fields', () {
      final preview = FeedbackReportPreview(report: _report());
      expect(preview.isRedactable('category'), isFalse);
      expect(preview.isRedactable('severity'), isFalse);
      expect(preview.isRedactable('breadcrumbs'), isFalse);
      expect(preview.isRedactable('deviceInfo.'), isFalse);
      expect(preview.isRedactable('nonsense'), isFalse);
    });
  });

  group('redactField / unredactField', () {
    test('redactField records the path immutably', () {
      final preview = FeedbackReportPreview(report: _report());
      final redacted = preview.redactField('platform');
      expect(redacted.userRedactedFields, {'platform'});
      expect(preview.userRedactedFields, isEmpty);
    });

    test('redactField throws on a non-redactable path', () {
      final preview = FeedbackReportPreview(report: _report());
      expect(() => preview.redactField('category'), throwsArgumentError);
    });

    test('unredactField removes a previously redacted path', () {
      final preview = FeedbackReportPreview(
        report: _report(),
      ).redactField('platform').redactField('locale').unredactField('platform');
      expect(preview.userRedactedFields, {'locale'});
    });
  });

  group('displayJson', () {
    test('marks redacted fields visibly instead of removing them', () {
      final json = FeedbackReportPreview(report: _report())
          .redactField('platform')
          .redactField('deviceInfo.model')
          .displayJson();
      expect(json['platform'], FeedbackReportPreview.redactedMarker);
      expect(
        (json['deviceInfo'] as Map<String, dynamic>)['model'],
        FeedbackReportPreview.redactedMarker,
      );
      // Untouched fields stay visible.
      expect(json['title'], 'Add crash');
      expect((json['deviceInfo'] as Map<String, dynamic>)['osVersion'], '16');
    });
  });

  group('toSubmittableReport', () {
    test('replaces redacted values and carries the paths', () {
      final submittable = FeedbackReportPreview(report: _report())
          .redactField('locale')
          .redactField('deviceInfo.model')
          .toSubmittableReport();
      expect(submittable.locale, FeedbackReportPreview.redactedMarker);
      expect(
        submittable.deviceInfo!['model'],
        FeedbackReportPreview.redactedMarker,
      );
      expect(submittable.deviceInfo!['osVersion'], '16');
      expect(
        submittable.userRedactedFields,
        containsAll(['locale', 'deviceInfo.model']),
      );
    });

    test('merges with paths already on the underlying report', () {
      final report = _report().copyWith(userRedactedFields: ['title']);
      final submittable = FeedbackReportPreview(
        report: report,
      ).redactField('platform').toSubmittableReport();
      expect(
        submittable.userRedactedFields.toSet(),
        {'title', 'platform'},
      );
    });

    test('no user redactions returns an equivalent report', () {
      final report = _report();
      final submittable = FeedbackReportPreview(
        report: report,
      ).toSubmittableReport();
      expect(submittable, report);
    });

    test('redacting a null field leaves it null', () {
      final report = FeedbackReport(
        category: FeedbackCategory.featureRequest,
        message: 'm',
      );
      final submittable = FeedbackReportPreview(
        report: report,
      ).redactField('title').toSubmittableReport();
      expect(submittable.title, isNull);
    });
  });
}
