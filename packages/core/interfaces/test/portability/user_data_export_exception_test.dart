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
      final cause = Exception('unreadable secure store');
      final exception = ExportSessionUnavailableException(cause: cause);

      expect(exception, isA<UserDataExportException>());
      expect(exception.cause, same(cause));
      expect(exception.message, contains('could not be read'));
    });

    test('toString names the type and message', () {
      final exception = ExportSessionUnavailableException(
        cause: Exception('unreadable secure store'),
      );

      expect(
        exception.toString(),
        'ExportSessionUnavailableException: '
        'The cached session could not be read on this device.',
      );
    });
  });
}
