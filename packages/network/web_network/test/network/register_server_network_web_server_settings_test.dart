import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:dio_network/dio_network.dart'
    show NotificationRemoteDataSourceImpl, SystemSettingsRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';
import 'package:web_network/src/network/register_server_network_web.dart';

/// #807: the per-origin server settings and notification remotes are the web
/// network installer's to register, on the same convention as native's.
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

  group('registerServerNetworkWeb server settings remotes (#807)', () {
    test('registers a SystemSettingsRemoteDataSource, as the interface', () {
      expect(
        container.get<SystemSettingsRemoteDataSource>(),
        isA<SystemSettingsRemoteDataSourceImpl>(),
      );
      expect(
        container.isRegistered<SystemSettingsRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers a NotificationRemoteDataSource, as the interface', () {
      expect(
        container.get<NotificationRemoteDataSource>(),
        isA<NotificationRemoteDataSourceImpl>(),
      );
      expect(
        container.isRegistered<NotificationRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<AdminHouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
    });
  });
}
