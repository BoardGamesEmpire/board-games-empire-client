import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart' show LogRecordFormatter;

import 'package:web_network/src/network/web_clock_skew_diagnostic_interceptor.dart';

import '../support/scripted_adapter.dart';

void main() {
  // Deliberately a literal IMF-fixdate rather than `HttpDate.format`: this
  // suite stays `dart:io`-free, so it could run in a browser as it stands
  // (#369).
  const readableDate = 'Wed, 10 Sep 2026 12:00:00 GMT';

  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;
  late Level previous;

  setUp(() {
    records = [];
    previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    sub = Logger.root.onRecord.listen(records.add);
  });

  tearDown(() async {
    await sub.cancel();
    Logger.root.level = previous;
  });

  // Mirrors WebDioFactory: validateStatus:(_)=>true, so every HTTP status
  // arrives through onResponse and only transport failures reach onError.
  Dio buildDio(ScriptedAdapter adapter) =>
      Dio(
          BaseOptions(
            baseUrl: 'https://bge.example.com',
            validateStatus: (_) => true,
          ),
        )
        ..httpClientAdapter = adapter
        ..interceptors.add(WebClockSkewDiagnosticInterceptor());

  List<LogRecord> warningsIn(List<LogRecord> rs) =>
      rs.where((r) => r.level == Level.WARNING).toList();

  group('WebClockSkewDiagnosticInterceptor', () {
    test('warns once two responses in a row carry no Date header', () async {
      final dio = buildDio(ScriptedAdapter());

      await dio.get<dynamic>('/anything');
      await dio.get<dynamic>('/anything');

      final warns = warningsIn(records);
      expect(warns, hasLength(1));
      expect(warns.single.loggerName, 'bge.web.network.clock_skew');
      // A stripped header and an unparsable one are different deployment
      // faults, so the report distinguishes them.
      expect(
        LogRecordFormatter.contextOf(warns.single)?['date_header'],
        isNull,
      );
    });

    test('warns when the Date header is present but unparsable', () async {
      const obsolete = 'Wednesday, 10-Sep-26 12:00:00 GMT';
      final dio = buildDio(
        ScriptedAdapter(
          responseHeaders: {
            'date': [obsolete],
          },
        ),
      );

      await dio.get<dynamic>('/anything');
      await dio.get<dynamic>('/anything');

      // An obsolete-format value is exactly as unusable to the estimator as
      // a missing header: `tryParseHttpDate` returns null for both.
      final warns = warningsIn(records);
      expect(warns, hasLength(1));
      expect(
        LogRecordFormatter.contextOf(warns.single)?['date_header'],
        obsolete,
      );
    });

    test('stays silent for a single Date-less response — one omission is not a '
        'misconfiguration', () async {
      final dio = buildDio(ScriptedAdapter());

      // RFC 9110 lets a clockless server omit `Date`, and an intermediary's
      // own error page (a gateway 502) may omit it while the origin behind
      // it is configured correctly. Warning on that would report a
      // deployment fault that does not exist — and it would survive into a
      // feedback report.
      await dio.get<dynamic>('/anything');

      expect(warningsIn(records), isEmpty);
    });

    test(
      'stays silent when the first response carries a readable Date',
      () async {
        final dio = buildDio(
          ScriptedAdapter(
            responseHeaders: {
              'date': [readableDate],
            },
          ),
        );

        await dio.get<dynamic>('/anything');

        expect(warningsIn(records), isEmpty);
      },
    );

    test(
      'warns at most once, however many Date-less responses follow',
      () async {
        final dio = buildDio(ScriptedAdapter());

        await dio.get<dynamic>('/one');
        await dio.get<dynamic>('/two');
        await dio.get<dynamic>('/three');

        // A missing Date recurs on every request; the non-goal is a line per
        // response.
        expect(warningsIn(records), hasLength(1));
      },
    );

    test(
      'never warns once a readable Date has answered the question',
      () async {
        final dio = buildDio(
          ScriptedAdapter(
            responseHeaders: {
              'date': [readableDate],
            },
          ),
        );

        await dio.get<dynamic>('/with-date');
        // Later responses without the header are not the condition this
        // reports: the origin has already been shown to expose `Date`, so the
        // deployment is not misconfigured and the estimator is being fed.
        // Two of them, so this cannot pass merely by not reaching the
        // threshold.
        dio.httpClientAdapter = ScriptedAdapter();
        await dio.get<dynamic>('/without-date');
        await dio.get<dynamic>('/without-date-again');

        expect(warningsIn(records), isEmpty);
      },
    );

    test(
      'stays silent for a transport failure, which carries no headers',
      () async {
        final dio = buildDio(
          ScriptedAdapter(
            error: DioException.connectionError(
              requestOptions: RequestOptions(path: '/anything'),
              reason: 'refused',
            ),
          ),
        );

        await expectLater(
          dio.get<dynamic>('/anything'),
          throwsA(isA<DioException>()),
        );

        // No response means no evidence either way — the same reason
        // ClockSkewInterceptor does not override onError.
        expect(warningsIn(records), isEmpty);
      },
    );

    test('delivers the response unchanged', () async {
      final dio = buildDio(ScriptedAdapter());

      final response = await dio.get<dynamic>('/anything');

      expect(response.statusCode, 200);
    });
  });
}
