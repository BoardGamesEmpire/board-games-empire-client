import 'package:interfaces/portability.dart';
import 'package:test/test.dart';

void main() {
  group('ExportNotAuthenticatedException', () {
    test(
      'is a UserDataExportException with a default message and no cause',
      () {
        const exception = ExportNotAuthenticatedException();

        expect(exception, isA<UserDataExportException>());
        expect(exception.message, contains('authenticated session'));
        expect(exception.cause, isNull);
      },
    );

    test('toString names the type and message', () {
      const exception = ExportNotAuthenticatedException();

      expect(
        exception.toString(),
        'ExportNotAuthenticatedException: '
        'An authenticated session is required to export user data.',
      );
    });
  });

  group('ExportSessionUnavailableException', () {
    test('is a UserDataExportException carrying the wrapped cause', () {
      final cause = Exception('offline');
      final exception = ExportSessionUnavailableException(cause: cause);

      expect(exception, isA<UserDataExportException>());
      expect(exception.cause, same(cause));
      expect(exception.message, contains('could not be verified'));
    });

    test('toString names the type and message', () {
      final exception = ExportSessionUnavailableException(
        cause: Exception('offline'),
      );

      expect(
        exception.toString(),
        'ExportSessionUnavailableException: '
        'Your session could not be verified. Check your connection and '
        'try again.',
      );
    });
  });

  group('ExportUnknownServerException', () {
    test('embeds the unresolved server id and defaults cause to null', () {
      final exception = ExportUnknownServerException(serverId: 'srv_123');

      expect(exception, isA<UserDataExportException>());
      expect(exception.serverId, 'srv_123');
      expect(exception.message, contains('srv_123'));
      expect(exception.cause, isNull);
    });

    test('retains an optional wrapped cause', () {
      final cause = Exception('corrupt identity');
      final exception = ExportUnknownServerException(
        serverId: 'srv_123',
        cause: cause,
      );

      expect(exception.cause, same(cause));
    });

    test('toString names the type and message', () {
      final exception = ExportUnknownServerException(serverId: 'srv_123');

      expect(
        exception.toString(),
        'ExportUnknownServerException: '
        'No server configuration could be resolved for id "srv_123". '
        'It may be missing, or its stored identity may be unreadable.',
      );
    });
  });
}
