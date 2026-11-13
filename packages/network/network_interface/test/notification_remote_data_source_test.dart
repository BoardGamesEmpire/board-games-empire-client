import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('NotificationRemoteException (#807)', () {
    final cause = StateError('underneath');
    // Built at run time, so the failures below are not const.
    final message = ['no', 'pe'].join();
    final failures =
        <({NotificationRemoteException failure, String name, int status})>[
          (
            failure: NotificationPermanentException(
              message,
              statusCode: 400,
              cause: cause,
            ),
            name: 'NotificationPermanentException',
            status: 400,
          ),
          (
            failure: NotificationTransientException(
              message,
              statusCode: 503,
              cause: cause,
            ),
            name: 'NotificationTransientException',
            status: 503,
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
      final failure = NotificationTransientException(message);

      expect(failure.statusCode, isNull);
      expect(failure.cause, isNull);
      expect(
        failure.toString(),
        'NotificationTransientException(message: nope, statusCode: null)',
      );
    });
  });
}
