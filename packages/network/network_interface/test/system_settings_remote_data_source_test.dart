import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('SystemSettingsRemoteException (#807)', () {
    final cause = StateError('underneath');
    // Built at run time, so the failures below are not const.
    final message = ['no', 'pe'].join();
    final failures =
        <({SystemSettingsRemoteException failure, String name, int status})>[
          (
            failure: SystemSettingsForbiddenException(
              message,
              statusCode: 403,
              cause: cause,
            ),
            name: 'SystemSettingsForbiddenException',
            status: 403,
          ),
          (
            failure: SmtpPasswordRequiredException(
              message,
              statusCode: 400,
              cause: cause,
            ),
            name: 'SmtpPasswordRequiredException',
            status: 400,
          ),
          (
            failure: MailNotConfiguredException(
              message,
              statusCode: 409,
              cause: cause,
            ),
            name: 'MailNotConfiguredException',
            status: 409,
          ),
          (
            failure: MailQueueUnavailableException(
              message,
              statusCode: 503,
              cause: cause,
            ),
            name: 'MailQueueUnavailableException',
            status: 503,
          ),
          (
            failure: SystemSettingsPermanentException(
              message,
              statusCode: 400,
              cause: cause,
            ),
            name: 'SystemSettingsPermanentException',
            status: 400,
          ),
          (
            failure: SystemSettingsTransientException(
              message,
              statusCode: 500,
              cause: cause,
            ),
            name: 'SystemSettingsTransientException',
            status: 500,
          ),
        ];

    for (final (:failure, :name, :status) in failures) {
      test('$name carries its message, status and cause', () {
        expect(failure, isA<Exception>());
        expect(failure.message, 'nope');
        expect(failure.statusCode, status);
        expect(failure.cause, same(cause));
        expect(
          failure.toString(),
          '$name(message: nope, statusCode: $status)',
        );
      });
    }

    test('statusCode and cause are null when not given', () {
      final failure = SystemSettingsTransientException(message);

      expect(failure.statusCode, isNull);
      expect(failure.cause, isNull);
      expect(
        failure.toString(),
        'SystemSettingsTransientException(message: nope, statusCode: null)',
      );
    });
  });
}
