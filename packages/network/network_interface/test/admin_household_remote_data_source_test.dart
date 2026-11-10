import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('AdminHouseholdRemoteDataSource.queryLength', () {
    int length(String text) => AdminHouseholdRemoteDataSource.queryLength(text);

    test('counts plain text by code unit', () {
      expect(length('ab'), 2);
      expect(length(''), 0);
    });

    test('counts a surrogate pair once, as the server does', () {
      expect(length('\u{1F600}'), 1);
      expect(length('a\u{1F600}'), 2);
    });

    test('counts a presentation sequence once', () {
      expect(length('\u{2764}\u{FE0F}'), 1);
    });
  });

  group('AdminHouseholdRemoteException (#685)', () {
    final cause = StateError('underneath');
    final message = ['no', 'pe'].join();
    final failures = <String, AdminHouseholdRemoteException>{
      'Forbidden': AdminHouseholdForbiddenException(
        message,
        statusCode: 403,
        cause: cause,
      ),
      'NotFound': AdminHouseholdNotFoundException(
        message,
        statusCode: 404,
        cause: cause,
      ),
      'NotDeleted': AdminHouseholdNotDeletedException(
        message,
        statusCode: 409,
        cause: cause,
      ),
      'Permanent': AdminHouseholdPermanentException(
        message,
        statusCode: 400,
        cause: cause,
      ),
      'Transient': AdminHouseholdTransientException(
        message,
        statusCode: 503,
        cause: cause,
      ),
    };

    const statuses = {
      'Forbidden': 403,
      'NotFound': 404,
      'NotDeleted': 409,
      'Permanent': 400,
      'Transient': 503,
    };

    for (final MapEntry(key: kind, value: failure) in failures.entries) {
      test('$kind carries its message, status and cause', () {
        expect(failure, isA<AdminHouseholdRemoteException>());
        expect(failure, isA<Exception>());
        expect(failure.message, 'nope');
        expect(failure.statusCode, statuses[kind]);
        expect(failure.cause, same(cause));
        expect(
          failure.toString(),
          'AdminHousehold${kind}Exception(message: nope, '
          'statusCode: ${statuses[kind]})',
        );
      });
    }

    test('statusCode and cause are null when not given', () {
      final failure = AdminHouseholdTransientException(message);

      expect(failure.statusCode, isNull);
      expect(failure.cause, isNull);
      expect(
        failure.toString(),
        'AdminHouseholdTransientException(message: nope, statusCode: null)',
      );
    });
  });
}
