import 'package:observability/observability.dart';
import 'package:test/test.dart';

FeedbackReport _validBugReport() => FeedbackReport(
  category: FeedbackCategory.bug,
  severity: FeedbackSeverity.medium,
  message: 'the collection list flickers on resync',
  title: 'Collection flicker',
  appVersion: '0.1.0',
  platform: 'android',
  locale: 'en-US',
  deviceInfo: const {'model': 'Pixel 9'},
  clientRequestId: 'ck-001',
);

void main() {
  group('FeedbackReport construction', () {
    test('severity is required when category is bug', () {
      expect(
        () => FeedbackReport(category: FeedbackCategory.bug, message: 'm'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('severity is required when category is crash', () {
      expect(
        () => FeedbackReport(category: FeedbackCategory.crash, message: 'm'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('feature requests do not require a severity', () {
      final report = FeedbackReport(
        category: FeedbackCategory.featureRequest,
        message: 'dark mode for the kitchen table please',
      );
      expect(report.severity, isNull);
    });

    test('message must not be empty', () {
      expect(
        () => FeedbackReport(
          category: FeedbackCategory.featureRequest,
          message: '',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('context defaults to unknown, list fields default empty', () {
      final report = FeedbackReport(
        category: FeedbackCategory.featureRequest,
        message: 'm',
      );
      expect(report.context, FeedbackContext.unknown);
      expect(report.userRedactedFields, isEmpty);
      expect(report.breadcrumbs, isEmpty);
    });
  });

  group('FeedbackReport JSON', () {
    test('round-trips through toJson/fromJson', () {
      final report = _validBugReport().copyWith(
        breadcrumbs: [
          Breadcrumb(
            timestamp: DateTime.utc(2026, 6, 12),
            level: BgeLogLevel.info,
            loggerName: 'bge.test',
            message: 'crumb',
          ),
        ],
      );
      expect(FeedbackReport.fromJson(report.toJson()), report);
    });

    test('enums serialise to PascalCase wire strings matching the backend', () {
      final json = _validBugReport().toJson();
      expect(json['category'], 'Bug');
      expect(json['severity'], 'Medium');
      expect(json['context'], 'Unknown');
    });

    test('breadcrumbs serialise to maps, not Dart instances', () {
      final report = _validBugReport().copyWith(
        breadcrumbs: [
          Breadcrumb(
            timestamp: DateTime.utc(2026),
            level: BgeLogLevel.error,
            loggerName: 'bge.test',
            message: 'boom',
          ),
        ],
      );
      final crumbs = report.toJson()['breadcrumbs'] as List;
      expect(crumbs.single, isA<Map<String, dynamic>>());
    });
  });

  group('FeedbackReport.validate', () {
    test('a well-formed report has no violations', () {
      expect(_validBugReport().validate(), isEmpty);
      expect(_validBugReport().isValid, isTrue);
    });

    test('flags message over the backend cap', () {
      final report = _validBugReport().copyWith(
        message: 'x' * (FeedbackConstants.maxMessageLength + 1),
      );
      expect(report.validate(), contains(contains('message')));
      expect(report.isValid, isFalse);
    });

    test('flags title over the backend cap', () {
      final report = _validBugReport().copyWith(
        title: 't' * (FeedbackConstants.maxTitleLength + 1),
      );
      expect(report.validate(), contains(contains('title')));
    });

    test('flags metadata strings over their caps', () {
      final report = _validBugReport().copyWith(
        appVersion: 'v' * (FeedbackConstants.maxAppVersionLength + 1),
        platform: 'p' * (FeedbackConstants.maxPlatformLength + 1),
        locale: 'l' * (FeedbackConstants.maxLocaleLength + 1),
        clientRequestId: 'c' * (FeedbackConstants.maxClientRequestIdLength + 1),
      );
      final violations = report.validate();
      expect(violations, contains(contains('appVersion')));
      expect(violations, contains(contains('platform')));
      expect(violations, contains(contains('locale')));
      expect(violations, contains(contains('clientRequestId')));
    });

    test('flags userRedactedFields over the backend array cap', () {
      final report = _validBugReport().copyWith(
        userRedactedFields: List.generate(
          FeedbackConstants.maxRedactedFields + 1,
          (i) => 'deviceInfo.k$i',
        ),
      );
      expect(report.validate(), contains(contains('userRedactedFields')));
    });

    test('values exactly at the caps pass', () {
      final report = _validBugReport().copyWith(
        message: 'x' * FeedbackConstants.maxMessageLength,
        title: 't' * FeedbackConstants.maxTitleLength,
      );
      expect(report.validate(), isEmpty);
    });
  });

  // The wire key is produced by json_serializable from the Dart field
  // name — there is no `@JsonKey` and no `field_rename`, so the rename in
  // #161 only reaches the wire once codegen re-runs. Nothing else in the
  // suite would notice a stale `.g.dart` still emitting `correlationKey`;
  // the backend would, with a 400, because its validation pipe runs
  // `forbidNonWhitelisted: true`. These assertions are the local
  // equivalent of that 400.
  group('FeedbackReport wire shape', () {
    test('carries the idempotency token as clientRequestId', () {
      final json = _validBugReport().toJson();

      expect(json['clientRequestId'], 'ck-001');
    });

    test('does not emit the pre-#161 correlationKey', () {
      final json = _validBugReport().toJson();

      expect(json.containsKey('correlationKey'), isFalse);
    });

    test('ignores an unrecognised correlationKey on decode rather than '
        'throwing — which is why a stale persisted record needs reaping, '
        'not a decode fallback', () {
      final json = _validBugReport().toJson()
        ..remove('clientRequestId')
        ..['correlationKey'] = 'ck-001';

      final decoded = FeedbackReport.fromJson(json);

      expect(decoded.clientRequestId, isNull);
    });
  });
}
