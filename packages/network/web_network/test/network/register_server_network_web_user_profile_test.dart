import 'dart:convert';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show UserProfileRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';
import 'package:web_network/src/network/register_server_network_web.dart';

/// #547: the per-origin profile remote is the web network installer's to
/// register, on the same convention as native's and beside the user remote.
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

  UserProfileRemoteDataSource remote() =>
      container.get<UserProfileRemoteDataSource>();

  group('registerServerNetworkWeb profile remote (#547)', () {
    test('registers the interface, not the implementation type', () {
      // Native's implementation, not a web twin.
      expect(container.isRegistered<UserProfileRemoteDataSource>(), isTrue);
      expect(remote(), isA<UserProfileRemoteDataSourceImpl>());
      expect(
        container.isRegistered<UserProfileRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('resolves as one instance over the shared per-server Dio', () async {
      expect(remote(), same(remote()));
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');

      // The canned answer arrives only if the remote sends through the Dio
      // the container holds.
      container.get<Dio>().httpClientAdapter = CannedAdapter(
        body: jsonEncode({
          'profile': {
            'userId': 'u_1',
            'username': 'ana',
            'willingToTeach': true,
            'openToNewPlayers': true,
            'hostingCapability': false,
          },
        }),
        statusCode: 200,
      );

      final profile = await remote().fetchOwn();

      expect(profile.username, 'ana');
    });
  });
}
