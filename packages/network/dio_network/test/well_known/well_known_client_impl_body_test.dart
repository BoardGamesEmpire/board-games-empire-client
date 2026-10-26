import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

const _kServerUrl = 'https://api.example.com';

void main() {
  // A real Dio, unlike the suite next door: that one stubs `Dio` itself, so
  // Dio's own body handling never runs and this hazard cannot be seen from it.
  group('responseType is pinned per request (#360)', () {
    for (final type in [ResponseType.bytes, ResponseType.stream]) {
      test(
        'an injected Dio set to responseType.${type.name} still reports a 502 '
        'as an answer, not an unreachable server',
        () async {
          final dio = cannedDio(body: '<html>Gateway</html>', statusCode: 502)
            ..options.responseType = type;

          await expectLater(
            WellKnownClientImpl.withDio(dio).fetchIdentity(_kServerUrl),
            throwsA(
              isA<WellKnownServerErrorException>().having(
                (e) => e.statusCode,
                'statusCode',
                502,
              ),
            ),
          );
        },
      );
    }

    // The other way into `_interpret`: with `validateStatus` left at Dio's
    // default, a 503 arrives as a thrown `DioException`, and its response
    // reaches `_interpret` from the catch. The server answered, so it is
    // failing, not unreachable (#389).
    test('a thrown 503 is a server error, not unreachable', () async {
      final dio = cannedDio(
        body: '<html>Service Unavailable</html>',
        statusCode: 503,
        permissiveStatus: false,
      );

      await expectLater(
        WellKnownClientImpl.withDio(dio).fetchIdentity(_kServerUrl),
        throwsA(
          isA<WellKnownServerErrorException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });
  });
}
