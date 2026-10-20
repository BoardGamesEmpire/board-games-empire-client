import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show HouseholdInviteRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #455: the per-origin household invite remote is the web network
/// installer's to register, on the same convention as native's and beside
/// the other remotes. It shares the per-origin Dio, which carries the base
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

  HouseholdInviteRemoteDataSource remote() =>
      container.get<HouseholdInviteRemoteDataSource>();

  group('registerServerNetworkWeb household invite remote (#455)', () {
    test('registers native\'s implementation under the interface', () {
      expect(container.isRegistered<HouseholdInviteRemoteDataSource>(), isTrue);
      expect(remote(), isA<HouseholdInviteRemoteDataSourceImpl>());
      expect(
        container.isRegistered<HouseholdInviteRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers beside the household remote, not instead of it', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
    });

    test('a refusal from the API reaches the caller as one, over the '
        'registered Dio', () async {
      // The factory's permissive validateStatus is what lets the remote read
      // the envelope at all.
      container.get<Dio>().httpClientAdapter = CannedAdapter(
        body: jsonEncode({
          'statusCode': 409,
          'message': 'Already settled.',
          'error': 'Conflict',
        }),
        statusCode: 409,
      );

      await expectLater(
        remote().withdraw('i_1'),
        throwsA(
          isA<HouseholdInviteRefusedException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });
  });
}
