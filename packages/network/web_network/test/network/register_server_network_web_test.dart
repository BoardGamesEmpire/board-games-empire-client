// `dart:io` is a test-only import: these tests run on the VM, and it is
// only used to *format* a Date header. The web production path stays
// `dart:io`-free — parsing goes through the pure-Dart `tryParseHttpDate`.
// It is also what keeps this suite off the browser matrix (#369).
import 'dart:async';
import 'dart:io';

import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show
        ClockSkewInterceptor,
        DioFactory,
        NetworkLogInterceptor,
        TokenStorageService;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart' show LogRecordFormatter;

import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/network/register_server_network_web.dart';
import 'package:web_network/src/network/web_clock_skew_diagnostic_interceptor.dart';
import 'package:web_network/src/network/web_dio_factory.dart';

import '../support/scripted_adapter.dart';
import '../support/server_identity_fixture.dart';

void main() {
  late DependencyContainerImpl container;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> logs;
  late Level previousLevel;

  setUp(() {
    container = DependencyContainerImpl();
    records = [];
    previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    logs = Logger.root.onRecord.listen(records.add);
  });

  tearDown(() async {
    await logs.cancel();
    Logger.root.level = previousLevel;
    await container.dispose();
  });

  void register({String origin = 'https://bge.example.com'}) =>
      registerServerNetworkWeb(
        container: container,
        identity: testServerIdentity(),
        // Uri.base has no origin on the VM, so tests inject one; production
        // defaults to WebDioFactory.currentOrigin (the address bar).
        originProvider: () => origin,
      );

  group('registerServerNetworkWeb', () {
    test('registers WebDioFactory as the DioFactory', () {
      register();

      expect(container.get<DioFactory>(), isA<WebDioFactory>());
    });

    test('registers a shared Dio whose baseUrl comes from the origin '
        'provider, normalized without a trailing slash', () {
      register(origin: 'https://bge.example.com/');

      final dio = container.get<Dio>();
      expect(dio.options.baseUrl, 'https://bge.example.com');
    });

    test('registers WebAuthRepositoryImpl as the AuthRepository', () {
      register();

      expect(container.get<AuthRepository>(), isA<WebAuthRepositoryImpl>());
    });

    test('registers no TokenStorageService — the browser owns the session '
        'cookie', () {
      register();

      expect(container.isRegistered<TokenStorageService>(), isFalse);
    });

    test('registers the skew-corrected clock, not the pass-through null '
        'object', () {
      register();

      // #118: web reads the origin's `Date` header like native does, so it
      // gets the estimator. `LocalClockService` was the documented web
      // fallback while no feeder existed; nothing registered it.
      expect(container.get<ClockService>(), isA<ServerSkewClockService>());
    });

    test('installs the clock-skew feeder in the shared Dio', () {
      register();

      expect(
        container.get<Dio>().interceptors.whereType<ClockSkewInterceptor>(),
        hasLength(1),
      );
    });

    test('installs the network log interceptor first of the three it '
        'composes, ahead of the feeder and the Date diagnostic', () {
      register();

      // #282: first so it observes every request and its resolution,
      // matching native's ordering and rationale. Asserting the order, not
      // just the presence — "first" is the decision, and a membership check
      // would not notice it moving.
      //
      // "First" means first of the three installed here, NOT index 0: Dio
      // seeds every stack with its own ImplyContentTypeInterceptor ahead of
      // anything a caller passes, on native exactly as here.
      final ours = container
          .get<Dio>()
          .interceptors
          .where(
            (i) =>
                i is NetworkLogInterceptor ||
                i is ClockSkewInterceptor ||
                i is WebClockSkewDiagnosticInterceptor,
          )
          .toList();

      expect(ours, hasLength(3));
      expect(ours[0], isA<NetworkLogInterceptor>());
      expect(ours[1], isA<ClockSkewInterceptor>());
      expect(ours[2], isA<WebClockSkewDiagnosticInterceptor>());
    });

    test('the installed log interceptor records what the web stack sends, '
        'with the URI redacted', () async {
      register();
      final dio = container.get<Dio>()..httpClientAdapter = ScriptedAdapter();

      await dio.get<dynamic>('/session', queryParameters: {'token': 'secret'});

      // Presence in the list is not the claim — that it actually emits
      // through the web stack is. Web had no record of any request before
      // #282.
      final network = records.where((r) => r.loggerName == 'bge.network');
      expect(network, isNotEmpty);
      final uris = network
          .map(LogRecordFormatter.contextOf)
          .whereType<Map<String, dynamic>>()
          .map((c) => c['uri'])
          .whereType<String>();
      expect(uris, contains('https://bge.example.com/session'));
      // The redaction contract holds on web exactly as on native: the query
      // string reaches no part of a record. Asserted over the rendered line,
      // which carries the encoded context — `LogRecord.toString()` renders
      // `ContextLogMessage.text` alone, so a matcher over it would pass even
      // with the secret sitting in the context.
      const rendered = LogRecordFormatter(includeTimestamp: false);
      expect(
        records.map(rendered.formatLine).join(),
        isNot(contains('secret')),
      );
    });

    test('feeds the registered clock from the response Date header', () async {
      register();
      final clock = container.get<ClockService>();
      final dio = container.get<Dio>();

      // Relative to now, because the estimator discards anything beyond
      // maxPlausibleSkew (24h) before it reaches the pipeline. Truncated to
      // whole seconds so format → parse round-trips exactly.
      final now = DateTime.now().toUtc();
      final serverDate = DateTime.utc(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
      ).subtract(const Duration(minutes: 5));
      dio.httpClientAdapter = ScriptedAdapter(
        responseHeaders: {
          HttpHeaders.dateHeader: [HttpDate.format(serverDate)],
        },
      );

      // Two responses: the estimator establishes an estimate only when two
      // consecutive samples agree, so one response proves nothing.
      await dio.get<dynamic>('/anything');
      expect(
        clock.skewEstimate,
        isNull,
        reason: 'one sample must not establish an estimate on its own',
      );

      await dio.get<dynamic>('/anything');

      final estimate = clock.skewEstimate;
      expect(
        estimate,
        isNotNull,
        reason: 'recorder must be the registered clock',
      );
      expect(
        (estimate! - const Duration(minutes: 5)).abs(),
        lessThan(const Duration(seconds: 5)),
      );
    });

    test(
      'leaves the estimate null when responses carry no Date header',
      () async {
        register();
        final clock = container.get<ClockService>();
        final dio = container.get<Dio>()..httpClientAdapter = ScriptedAdapter();

        final response = await dio.get<dynamic>('/anything');
        await dio.get<dynamic>('/anything');

        // The supported degraded state: no estimate, no error, response still
        // delivered. `nowUtc()` falls back to the raw local clock.
        expect(clock.skewEstimate, isNull);
        expect(response.statusCode, 200);
      },
    );

    test('disposes the clock with the container', () async {
      register();
      final clock = container.get<ClockService>();

      await container.dispose();

      // A disposed estimator emits its final estimate and completes.
      await expectLater(clock.watchSkew(), emitsInOrder([null, emitsDone]));
    });
  });
}
