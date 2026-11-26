import 'dart:convert';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show ApiKeyRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';
import 'package:web_network/src/network/register_server_network_web.dart';

/// #1028: the per-origin API key remote is the web network installer's to
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

  ApiKeyRemoteDataSource remote() => container.get<ApiKeyRemoteDataSource>();

  group('registerServerNetworkWeb API key remote (#1028)', () {
    test("registers native's implementation under the interface", () {
      expect(container.isRegistered<ApiKeyRemoteDataSource>(), isTrue);
      expect(remote(), isA<ApiKeyRemoteDataSourceImpl>());
      expect(container.isRegistered<ApiKeyRemoteDataSourceImpl>(), isFalse);
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
          'statusCode': 403,
          'message': 'Sign in again.',
          'error': 'Forbidden',
          'code': 'API_KEY_NEEDS_RECENT_SIGN_IN',
        }),
        statusCode: 403,
      );

      await expectLater(
        remote().delete('k_1'),
        throwsA(
          isA<ApiKeyNeedsRecentSignInException>().having(
            (e) => e.apiMessage,
            'apiMessage',
            'Sign in again.',
          ),
        ),
      );
    });
  });
}
