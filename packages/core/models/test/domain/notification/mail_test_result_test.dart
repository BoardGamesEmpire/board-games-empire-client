import 'package:models/domain.dart';
import 'package:test/test.dart';

UnreadNotification _note(String type, Map<String, Object?> payload) =>
    UnreadNotification(
      id: 'n1',
      type: type,
      payload: payload,
      createdAt: DateTime.utc(2026, 11, 12),
    );

void main() {
  group('MailTestResult.fromNotification', () {
    test('reads a sent outcome', () {
      final result = MailTestResult.fromNotification(
        _note('MailTestResult', {
          'outcome': 'sent',
          'code': null,
          'message': 'Sent',
        }),
      );
      expect(result!.sent, isTrue);
      expect(result.failure, isNull);
      expect(result.message, 'Sent');
    });

    test('reads a sent outcome as sent even when it carries a code', () {
      final result = MailTestResult.fromNotification(
        _note('MailTestResult', {
          'outcome': 'sent',
          'code': 'MAIL_AUTH_FAILED',
          'message': 'Sent',
        }),
      );
      expect(result!.sent, isTrue);
      expect(result.failure, isNull);
    });

    test('reads a known failure code', () {
      final result = MailTestResult.fromNotification(
        _note('MailTestResult', {
          'outcome': 'failed',
          'code': 'MAIL_AUTH_FAILED',
          'message': 'm',
        }),
      );
      expect(result!.sent, isFalse);
      expect(result.failure, MailFailure.authFailed);
    });

    test('reads an unknown code as unknown', () {
      final result = MailTestResult.fromNotification(
        _note('MailTestResult', {
          'outcome': 'failed',
          'code': 'MAIL_NEW_THING',
          'message': 'm',
        }),
      );
      expect(result!.failure, MailFailure.unknown);
    });

    test('reads a missing or non-string code as unknown', () {
      for (final code in <Object?>[null, 7]) {
        final result = MailTestResult.fromNotification(
          _note('MailTestResult', {
            'outcome': 'failed',
            'code': code,
            'message': 'm',
          }),
        );
        expect(result!.failure, MailFailure.unknown);
      }
    });

    test('ignores another notification type', () {
      expect(
        MailTestResult.fromNotification(
          _note('HouseholdInviteReceived', {'outcome': 'sent', 'message': 'm'}),
        ),
        isNull,
      );
    });

    test('ignores an outcome it does not know', () {
      expect(
        MailTestResult.fromNotification(
          _note('MailTestResult', {'outcome': 'queued', 'message': 'm'}),
        ),
        isNull,
      );
    });

    test('ignores a payload without a string message', () {
      expect(
        MailTestResult.fromNotification(
          _note('MailTestResult', {'outcome': 'sent'}),
        ),
        isNull,
      );
      expect(
        MailTestResult.fromNotification(
          _note('MailTestResult', {'outcome': 'sent', 'message': 3}),
        ),
        isNull,
      );
    });
  });

  test('compares by value', () {
    const sent = MailTestResult(sent: true, failure: null, message: 'Sent');
    expect(
      sent,
      const MailTestResult(sent: true, failure: null, message: 'Sent'),
    );
    expect(
      sent,
      isNot(
        const MailTestResult(
          sent: false,
          failure: MailFailure.unknown,
          message: 'Sent',
        ),
      ),
    );
    expect(
      const MailTestResult(
        sent: false,
        failure: MailFailure.authFailed,
        message: 'm',
      ),
      isNot(
        const MailTestResult(
          sent: false,
          failure: MailFailure.tlsFailed,
          message: 'm',
        ),
      ),
    );
    expect(
      sent,
      isNot(const MailTestResult(sent: true, failure: null, message: 'Other')),
    );
  });
}
