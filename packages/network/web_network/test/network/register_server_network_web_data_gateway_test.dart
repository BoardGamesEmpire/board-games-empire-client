import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show DataGatewayRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #41: the per-origin DataGateway remote is the web network installer's to
/// register, on the same convention as native's and beside the household and
/// collection remotes. It shares the per-origin Dio, which carries the base
/// URL and the browser-owned session cookie.
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

  DataGatewayRemoteDataSource remote() =>
      container.get<DataGatewayRemoteDataSource>();

  group('registerServerNetworkWeb DataGateway remote (#41)', () {
    test('registers native\'s implementation under the interface', () {
      expect(remote(), isA<DataGatewayRemoteDataSourceImpl>());
      expect(
        container.isRegistered<DataGatewayRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
    });

    test('a 403 from the API reaches the caller as a refusal, over the '
        'registered Dio', () async {
      // The gating (#41) turns on this one answer, so it is pinned over the
      // web transport too: the factory's permissive validateStatus is what
      // lets the remote read the envelope at all.
      container.get<Dio>().httpClientAdapter = CannedAdapter(
        body: jsonEncode({
          'statusCode': 403,
          'message': 'You are not allowed to do that.',
          'error': 'Forbidden',
        }),
        statusCode: 403,
      );

      await expectLater(
        remote().fetchPage(limit: 1),
        throwsA(isA<DataGatewayForbiddenException>()),
      );
    });
  });
}
