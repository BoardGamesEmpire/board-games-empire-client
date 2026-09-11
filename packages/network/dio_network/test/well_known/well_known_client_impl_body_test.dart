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
              isA<WellKnownInvalidResponseException>().having(
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
    // default, a 502 arrives as a thrown `DioException` and the body reaches
    // the narrowing as `DioException.response.data`. That is the path the
    // narrowing comment is about, and nothing exercised it before.
    test(
      'a thrown non-2xx still reports the server as having answered',
      () async {
        final dio = cannedDio(
          body: '<html>Gateway</html>',
          statusCode: 502,
          permissiveStatus: false,
        );

        await expectLater(
          WellKnownClientImpl.withDio(dio).fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              502,
            ),
          ),
        );
      },
    );
  });
}
