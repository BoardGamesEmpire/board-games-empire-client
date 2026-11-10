import 'package:di/di.dart';
import 'package:dio_network/dio_network.dart'
    show AdminHouseholdRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #684: the per-origin staff households remote is the web network
/// installer's to register, on the same convention as native's and beside the
/// DataGateway remote.
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

  group('registerServerNetworkWeb admin household remote (#684)', () {
    test(
      "registers an AdminHouseholdRemoteDataSource on the server's Dio",
      () {
        expect(
          container.get<AdminHouseholdRemoteDataSource>(),
          isA<AdminHouseholdRemoteDataSourceImpl>(),
        );
        expect(
          container.isRegistered<AdminHouseholdRemoteDataSourceImpl>(),
          isFalse,
        );
      },
    );

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
    });
  });
}
