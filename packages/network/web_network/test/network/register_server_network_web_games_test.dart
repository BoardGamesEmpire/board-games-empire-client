import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show GamesRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #42: the per-origin games remote is the web network installer's to
/// register, on the same convention as native's and beside the other remotes.
/// It shares the per-origin Dio, which carries the base URL and the
/// browser-owned session cookie.
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

  GamesRemoteDataSource remote() => container.get<GamesRemoteDataSource>();

  group('registerServerNetworkWeb games remote (#42)', () {
    test("registers native's implementation under the interface", () {
      expect(remote(), isA<GamesRemoteDataSourceImpl>());
      expect(container.isRegistered<GamesRemoteDataSourceImpl>(), isFalse);
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
    });

    test('a catalog page reads over the registered Dio', () async {
      container.get<Dio>().httpClientAdapter = CannedAdapter(
        body: jsonEncode({
          'games': <Object>[],
          'pagination': {
            'page': 1,
            'limit': 1,
            'total': 0,
            'totalPages': 0,
            'hasMore': false,
          },
        }),
        statusCode: 200,
      );

      final page = await remote().fetchPage(limit: 1);

      expect(page.items, isEmpty);
    });
  });
}
