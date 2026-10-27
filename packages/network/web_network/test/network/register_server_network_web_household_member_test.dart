import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show HouseholdMemberRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #480: the per-origin household member remote is the web network
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

  HouseholdMemberRemoteDataSource remote() =>
      container.get<HouseholdMemberRemoteDataSource>();

  group('registerServerNetworkWeb household member remote (#480)', () {
    test('registers native\'s implementation under the interface', () {
      expect(container.isRegistered<HouseholdMemberRemoteDataSource>(), isTrue);
      expect(remote(), isA<HouseholdMemberRemoteDataSourceImpl>());
      expect(
        container.isRegistered<HouseholdMemberRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers beside the household and invite remotes, not instead '
        'of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<HouseholdInviteRemoteDataSource>(), isTrue);
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
        remote().remove('h_1', 'm_1'),
        throwsA(
          isA<HouseholdMemberRefusedException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });
  });
}
