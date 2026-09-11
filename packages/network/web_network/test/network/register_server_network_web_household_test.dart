import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show HouseholdRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// A household row as `GET /api/households` embeds it, trimmed to the fields
/// this suite reads. The full-fidelity fixture lives with the data source's own
/// tests (`dio_network/test/household/`); duplicating it here would be a second
/// copy of the wire shape to keep in step, and nothing below asserts on
/// mapping.
Map<String, dynamic> _row() => {
  'id': 'hh_1',
  'name': 'Game Night HQ',
  'description': null,
  'image': null,
  'deletedAt': null,
  'createdAt': '2026-01-15T10:30:00.000Z',
  'updatedAt': '2026-01-15T10:30:00.000Z',
  'members': <Map<String, dynamic>>[],
};

String _listBody() => jsonEncode({
  'households': [_row()],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 1,
    'totalPages': 1,
    'hasMore': false,
  },
});

/// Nest's rendered error envelope — `{statusCode, message, error}` — which
/// `isApiErrorEnvelope` treats as evidence the application itself answered.
String _envelopeBody(int status) => jsonEncode({
  'statusCode': status,
  'message': 'Forbidden resource',
  'error': 'Forbidden',
});

/// #125: the per-origin household remote is the web network installer's to
/// register, on the same convention as native's (`register_server_network.dart`)
/// and the `FeedbackTransport` beside it — it shares the per-origin Dio, which
/// carries the base URL and the browser-owned session cookie, and adds no auth
/// of its own.
///
/// The classification group covers the half of that reuse this suite can
/// reach. #125 reuses `HouseholdRemoteDataSourceImpl` rather than writing a
/// web twin, and the reuse rests on two things: `WebDioFactory` building
/// `BaseOptions` the data source's classifier needs — chiefly the permissive
/// `validateStatus`, without which Dio would throw before any status reached
/// it — and the browser adapter's own failure shapes.
///
/// **Only the first is pinned here.** These run on the VM and replace the
/// transport, so `BrowserHttpClientAdapter` is never constructed: what they
/// prove is that the *registered* remote over the *registered* Dio classifies
/// a given status and body the way the contract says. A browser-specific
/// failure shape — an XHR abort or a CORS rejection arriving as some other
/// `DioExceptionType` — would pass this file unchanged. #369 owns that gap;
/// it is why the reuse is not fully proved by any test today.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetworkWeb(
      container: container,
      identity: testServerIdentity(),
      // Uri.base has no origin on the VM, so tests inject one; production
      // defaults to WebDioFactory.currentOrigin (the address bar).
      originProvider: () => 'https://bge.example.com',
    );
  });

  tearDown(() async {
    await container.dispose();
  });

  /// Replaces the transport under the Dio the installer registered.
  void canned({required String body, required int status}) {
    container.get<Dio>().httpClientAdapter = CannedAdapter(
      body: body,
      statusCode: status,
    );
  }

  HouseholdRemoteDataSource remote() =>
      container.get<HouseholdRemoteDataSource>();

  group('registerServerNetworkWeb household remote (#125)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(remote(), isA<HouseholdRemoteDataSourceImpl>());
      // The negative half the name promises: registering the concrete type
      // alongside the interface would let a consumer bind to it and defeat
      // the seam, and every other assertion here would still pass.
      expect(container.isRegistered<HouseholdRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as a singleton — the hydrate and the create path share one '
        'instance over the shared per-origin Dio', () {
      expect(remote(), same(remote()));
    });

    test('requests through the Dio the installer registered, not one of its '
        'own', () async {
      // The adapter is swapped on the *registered* Dio, so a parsed result can
      // only mean the remote sent its request through that instance. A remote
      // holding a Dio of its own would miss the canned transport entirely and
      // attempt a real request to the fixture origin.
      canned(body: _listBody(), status: 200);

      final result = await remote().fetchHouseholds();

      expect(result.items, hasLength(1));
      expect(result.items.single.household.name, 'Game Night HQ');
    });
  });

  group('household classification over the web transport (#125)', () {
    // What makes the reuse safe is that WebDioFactory sets the same permissive
    // validateStatus native's DefaultDioFactory does, so every status reaches
    // the data source's own classifier rather than being thrown by Dio.
    test('an envelope-free 403 is transient — a proxy or WAF blocked the '
        'request, and it says nothing about the household API', () async {
      canned(body: '<html>Blocked by corporate proxy</html>', status: 403);

      await expectLater(
        remote().createHousehold(name: 'Game Night HQ'),
        throwsA(isA<HouseholdRemoteTransientException>()),
      );
    });

    test('an envelope-carrying 403 is permanent — the application itself '
        'refused', () async {
      canned(body: _envelopeBody(403), status: 403);

      await expectLater(
        remote().createHousehold(name: 'Game Night HQ'),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a transport failure with no response is transient', () async {
      container.get<Dio>().httpClientAdapter = FailingAdapter(
        DioExceptionType.connectionError,
        error: 'origin unreachable',
      );

      await expectLater(
        remote().fetchHouseholds(),
        throwsA(isA<HouseholdRemoteTransientException>()),
      );
    });

    test(
      'a 2xx whose body is not JSON is permanent, not a retry forever',
      () async {
        // The status-losing failure #265 fixed. Pinned here too because the web
        // leg is where a captive portal or an SPA catch-all is most likely to
        // answer with HTML under a 200.
        canned(body: '<html>Sign in to the hotel wifi</html>', status: 200);

        await expectLater(
          remote().fetchHouseholds(),
          throwsA(isA<HouseholdRemotePermanentException>()),
        );
      },
    );
  });
}
