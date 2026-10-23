import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show EventRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #496: the per-origin event remote is the web network installer's to
/// register, on the same convention as native's and beside the household,
/// collection and DataGateway remotes. It shares the per-origin Dio, which
/// carries the base URL and the browser-owned session cookie.
///
/// Without it the event hydrate would find no remote on web and skip.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetworkWeb(
      container: container,
      identity: testServerIdentity(),
      originProvider: () => 'https://bge.example.com',
    );
  });

  tearDown(() async {
    await container.dispose();
  });

  EventRemoteDataSource remote() => container.get<EventRemoteDataSource>();

  group('registerServerNetworkWeb event remote (#496)', () {
    test('registers native\'s implementation under the interface', () {
      expect(remote(), isA<EventRemoteDataSourceImpl>());
      expect(container.isRegistered<EventRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance', () {
      expect(remote(), same(remote()));
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
    });

    test('a 404 from the API reaches the caller as an event that is gone, '
        'over the registered Dio', () async {
      // The event screens turn on this one answer (#498), so it is pinned over
      // the web transport too: the factory's permissive validateStatus is what
      // lets the remote read the envelope at all.
      container.get<Dio>().httpClientAdapter = CannedAdapter(
        body: jsonEncode({
          'statusCode': 404,
          'message': 'Event ev_1 was not found.',
          'error': 'Not Found',
        }),
        statusCode: 404,
      );

      await expectLater(
        remote().fetchEvent('ev_1'),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
    });
  });
}
