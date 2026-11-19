import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('RealtimeUnavailableException (#473)', () {
    test('carries its message, status and cause', () {
      final cause = {'message': 'Your session is invalid'};
      // Built at run time, so the failure below is not const.
      final message = ['refu', 'sed'].join();

      final failure = RealtimeUnavailableException(
        message,
        statusCode: 401,
        cause: cause,
      );

      expect(failure, isA<Exception>());
      expect(failure.message, 'refused');
      expect(failure.statusCode, 401);
      expect(failure.cause, same(cause));
      expect(
        failure.toString(),
        'RealtimeUnavailableException(message: refused, statusCode: 401)',
      );
    });
  });

  test('a lease waits five seconds for a connect by default (#473)', () {
    expect(RealtimeConnection.connectTimeout, const Duration(seconds: 5));
  });

  test(
    "the synthetic disconnect frame is socket.io's reserved name (#473)",
    () {
      // A server event can never carry it, so the frame can't be mistaken.
      expect(RealtimeLease.disconnectEvent, 'disconnect');
    },
  );
}
