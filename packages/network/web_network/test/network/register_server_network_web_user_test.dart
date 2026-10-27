import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show UserRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #499: the per-origin user remote is the web network installer's to
/// register, on the same convention as native's and beside the household
/// invite remote. It shares the per-origin Dio, which carries the base URL and
/// the browser-owned session cookie.
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

  UserRemoteDataSource remote() => container.get<UserRemoteDataSource>();

  group('registerServerNetworkWeb user remote (#499)', () {
    test('registers the interface, not the implementation type', () {
      // Native's implementation, not a web twin.
      expect(container.isRegistered<UserRemoteDataSource>(), isTrue);
      expect(remote(), isA<UserRemoteDataSourceImpl>());
      expect(container.isRegistered<UserRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance over the shared per-server Dio', () async {
      expect(remote(), same(remote()));
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');

      // The canned answer arrives only if the remote sends through the Dio
      // the container holds.
      container.get<Dio>().httpClientAdapter = CannedAdapter(
        body: jsonEncode({
          'users': [
            {
              'id': 'u_2',
              'username': 'ana',
              'profile': {'displayName': 'Ana B', 'avatarUrl': null},
            },
          ],
          'pagination': {
            'page': 1,
            'limit': 20,
            'total': 1,
            'totalPages': 1,
            'hasMore': false,
          },
        }),
        statusCode: 200,
      );

      final page = await remote().searchUsers('ana');

      expect(page.items, const [
        UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B'),
      ]);
    });
  });
}
