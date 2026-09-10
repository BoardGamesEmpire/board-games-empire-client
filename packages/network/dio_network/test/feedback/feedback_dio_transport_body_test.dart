// Body-handling cases for FeedbackDioTransport, driven through a REAL Dio.
//
// The sibling suite stubs `Dio` itself, so Dio's own body handling never runs
// and it passes against the defect these cases exist for (#358): the transport
// asked for `Response<dynamic>`, and `dynamic` is the one type argument that
// reaches `ResponseType.json` WITHOUT entering `DioMixin.fetch`'s forcing
// block — the block is gated on `T != dynamic` (`dio_mixin.dart:419`) and
// `BaseOptions` already defaults to json (`options.dart:153`). So Dio decoded
// the body anyway, and a `FormatException` escaped as
// `DioException(type: unknown)` with **no response attached**: the status was
// gone before `_classifyDioException` could read it, and a permanent rejection
// classified transient and retried forever.
//
// Content type is not a promise about content. Every case below serves a body
// that contradicts its declared `application/json`, which is what a captive
// portal, SSO interstitial, WAF or proxy does — and what a dropped connection
// does to a genuine JSON response.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import 'package:dio_network/src/feedback/feedback_dio_transport.dart';

import '../support/canned_adapter.dart';

const _kHtml = '<!doctype html><html><body>Sign in to continue</body></html>';
const _kTruncated = '{"id":"fr_123","status":"acce';

void main() {
  const report = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'It broke',
    stackTrace: '#0 main (file.dart:1)',
    clientRequestId: 'key-1',
  );

  Future<void> send(Dio dio) => FeedbackDioTransport(dio).send(report);

  group('FeedbackDioTransport body handling (#358)', () {
    group('the status survives a body Dio cannot decode', () {
      test('HTML under application/json on a 400 is PERMANENT, status '
          'intact', () async {
        await expectLater(
          send(cannedDio(body: _kHtml, statusCode: 400)),
          throwsA(
            isA<FeedbackPermanentSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        );
      });

      test('HTML under application/json on a 403 is PERMANENT, status '
          'intact', () async {
        await expectLater(
          send(cannedDio(body: _kHtml, statusCode: 403)),
          throwsA(
            isA<FeedbackPermanentSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      });

      test('HTML under application/json on a 503 is transient, status '
          'intact', () async {
        await expectLater(
          send(cannedDio(body: _kHtml, statusCode: 503)),
          throwsA(
            isA<FeedbackTransientSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              503,
            ),
          ),
        );
      });

      test(
        'a truncated JSON body on a 429 is transient, status intact',
        () async {
          await expectLater(
            send(cannedDio(body: _kTruncated, statusCode: 429)),
            throwsA(
              isA<FeedbackTransientSubmissionException>().having(
                (e) => e.statusCode,
                'statusCode',
                429,
              ),
            ),
          );
        },
      );
    });

    group('an unparseable 2xx fails rather than reporting the report sent', () {
      test('HTML under application/json on a 200 is transient, not a silent '
          'success', () async {
        await expectLater(
          send(cannedDio(body: _kHtml, statusCode: 200)),
          throwsA(
            isA<FeedbackTransientSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              200,
            ),
          ),
        );
      });

      test('a truncated JSON body on a 201 is transient, not a silent '
          'success', () async {
        await expectLater(
          send(cannedDio(body: _kTruncated, statusCode: 201)),
          throwsA(
            isA<FeedbackTransientSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              201,
            ),
          ),
        );
      });

      test('HTML under text/html on a 201 is transient, not a silent '
          'success', () async {
        await expectLater(
          send(
            cannedDio(body: _kHtml, statusCode: 201, contentType: 'text/html'),
          ),
          throwsA(
            isA<FeedbackTransientSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              201,
            ),
          ),
        );
      });
    });

    group('the ordinary success path still completes', () {
      test('a 201 with the API envelope completes', () async {
        await send(cannedDio(body: '{"id":"fr_123"}', statusCode: 201));
      });

      test('a 201 with an EMPTY body completes — the wire contract is the '
          'status, and this transport reads nothing out of the body', () async {
        await send(cannedDio(body: '', statusCode: 201));
      });

      test(
        'a 201 whose body is valid JSON but not an object completes',
        () async {
          await send(cannedDio(body: '[]', statusCode: 201));
        },
      );

      test('a 201 whose body is only whitespace completes — a newline is a '
          'delivered report, not a page', () async {
        await send(cannedDio(body: '\n', statusCode: 201));
        await send(cannedDio(body: '   ', statusCode: 201));
        await send(
          cannedDio(body: '\t\n ', statusCode: 201, contentType: 'text/html'),
        );
      });
    });

    group('the isolate offload path', () {
      test('a truncated body above decodeJsonBody\'s 50 KB threshold still '
          'classifies transient with its status, and the FormatException '
          'identity survives the isolate hop', () async {
        final big = '{"reports":[${'{"id":"fr_1"},' * 4000}';
        expect(big.codeUnits.length, greaterThan(50 * 1024));

        await expectLater(
          send(cannedDio(body: big, statusCode: 201)),
          throwsA(
            isA<FeedbackTransientSubmissionException>()
                .having((e) => e.statusCode, 'statusCode', 201)
                .having((e) => e.cause, 'cause', isA<FormatException>()),
          ),
        );
      });

      test('a large page short-circuits on its first character — no parse, no '
          'isolate, and so no cause', () async {
        final big = '<!doctype html>${'<p>captive portal</p>' * 4000}';
        expect(big.codeUnits.length, greaterThan(50 * 1024));

        await expectLater(
          send(cannedDio(body: big, statusCode: 201)),
          throwsA(
            isA<FeedbackTransientSubmissionException>()
                .having((e) => e.statusCode, 'statusCode', 201)
                .having((e) => e.cause, 'cause', isNull),
          ),
        );
      });
    });

    group('responseType is pinned per request', () {
      for (final type in [ResponseType.bytes, ResponseType.stream]) {
        test(
          'an injected Dio set to responseType.${type.name} cannot reintroduce '
          'the status-losing cast',
          () async {
            final dio = cannedDio(body: _kHtml, statusCode: 400)
              ..options.responseType = type;

            await expectLater(
              send(dio),
              throwsA(
                isA<FeedbackPermanentSubmissionException>().having(
                  (e) => e.statusCode,
                  'statusCode',
                  400,
                ),
              ),
            );
          },
        );
      }
    });

    group('what already worked keeps working', () {
      test('HTML under text/html on a 400 is PERMANENT — no decode runs, so '
          'this path was never broken', () async {
        await expectLater(
          send(
            cannedDio(body: _kHtml, statusCode: 400, contentType: 'text/html'),
          ),
          throwsA(
            isA<FeedbackPermanentSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        );
      });

      test('a thrown badResponse from a non-permissive injected Dio is still '
          'classified by its status', () async {
        await expectLater(
          send(
            cannedDio(
              body: '{"error":"nope"}',
              statusCode: 400,
              permissiveStatus: false,
            ),
          ),
          throwsA(
            isA<FeedbackPermanentSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        );
      });
    });
  });
}
