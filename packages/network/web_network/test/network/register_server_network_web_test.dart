// `dart:io` is a test-only import: these tests run on the VM, and it is
// only used to *format* a Date header. The web production path stays
// `dart:io`-free — parsing goes through the pure-Dart `tryParseHttpDate`.
import 'dart:io';
import 'dart:typed_data';

import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show ClockSkewInterceptor, DioFactory, TokenStorageService;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/network/register_server_network_web.dart';
import 'package:web_network/src/network/web_dio_factory.dart';

const _kAuthBase = '/api/auth';

// Web has no MetaDB and no persisted ServerConfig: the identity is fetched
// from the serving origin's well-known document at runtime. The registration
// helper therefore takes a ServerIdentity directly — constructing a synthetic
// ServerConfig just to carry one is the wart this signature removes.
ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://bge.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

/// Stub adapter returning a canned response with configurable headers
/// (the `clock_skew_interceptor_test` pattern).
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.responseHeaders = const {}});

  final Map<String, List<String>> responseHeaders;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{}',
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      ...responseHeaders,
    },
  );
}

void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
  });

  tearDown(() async {
    await container.dispose();
  });

  void register({String origin = 'https://bge.example.com'}) =>
      registerServerNetworkWeb(
        container: container,
        identity: _identity(),
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
      dio.httpClientAdapter = _StubAdapter(
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
        final dio = container.get<Dio>()..httpClientAdapter = _StubAdapter();

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
