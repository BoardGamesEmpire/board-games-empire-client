import 'dart:async';

import 'package:data_gateway/data_gateway.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

const _kAuthBase = 'https://api.example.test/api/auth';

ScopedServer _server() => ScopedServer.fromConfig(
  ServerConfig(
    id: 'local-1',
    displayName: 'My Server',
    serverUrl: 'https://api.example.test',
    connectionState: ConnectionState.active,
    bgeServerId: 'server-1',
    cachedIdentity: ServerIdentity(
      serverId: 'server-1',
      issuer: 'https://api.example.test',
      wellKnownSchemaVersion: 1,
      name: 'Test BGE Server',
      deviceAuthorizationEndpoint: '$_kAuthBase/device',
      authBasePath: _kAuthBase,
      sessionEndpoint: '$_kAuthBase/get-session',
      signOutEndpoint: '$_kAuthBase/sign-out',
      passkeySupported: false,
      twoFactorSupported: false,
      anonymousAuthSupported: false,
      strategies: const [],
    ),
    lastIdentityFetchedAt: DateTime.utc(2024),
  ),
);

/// Records what the installer registers, and runs it on demand.
class _RecordingRehydrator implements SessionRehydrator {
  final Map<String, ({bool Function() isStale, Future<void> Function() run})>
  entries = {};

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) => entries[key] = (isStale: isStale, run: run);

  @override
  Future<void> rehydrateStale() async {
    for (final entry in entries.values) {
      if (entry.isStale()) await entry.run();
    }
  }
}

void main() {
  late DependencyContainerImpl container;
  late FakeDataGatewayRemote remote;

  setUp(() {
    container = DependencyContainerImpl();
    remote = FakeDataGatewayRemote();
    container.registerSingleton<DataGatewayRemoteDataSource>(remote);
  });

  tearDown(() async => container.dispose());

  Future<DataGatewayAccess> install() async {
    await const DataGatewayAccessInstaller().install(
      container,
      _server(),
      'user-1',
    );
    return container.get<DataGatewayAccess>();
  }

  test(
    'reads one row to learn whether this user may read DataGateways',
    () async {
      remote.listing([gateway('dg_1')]);

      final access = await install();
      await pumpEventQueue();

      expect(remote.calls, ['fetchPage(1, 1)']);
      expect(access.value.read, DataGatewayRead.granted);
    },
  );

  test('a 403 means this user may not read them', () async {
    remote.refusingReads();

    final access = await install();
    await pumpEventQueue();

    expect(access.value.read, DataGatewayRead.denied);
  });

  test('a failed read leaves the answer unknown rather than denied', () async {
    remote.onFetchPage = (_, _) async => throw unreachable();

    final access = await install();
    await pumpEventQueue();

    expect(access.value.read, DataGatewayRead.unknown);
  });

  test('does not hold up sign-in on the read', () async {
    final pending = Completer<PaginatedResult<DataGateway>>();
    remote.onFetchPage = (_, _) => pending.future;

    // A throw or a hang here would hold the session's activation, and the
    // shell converges a failed activation to a sign-out.
    final access = await install();

    expect(access.value.read, DataGatewayRead.unknown);
    pending.complete(pageOf(const []));
  });

  test('registers nothing where no DataGateway client is reachable', () async {
    final bare = DependencyContainerImpl();
    addTearDown(bare.dispose);

    await const DataGatewayAccessInstaller().install(bare, _server(), 'user-1');

    expect(bare.isRegistered<DataGatewayAccess>(), isFalse);
  });

  group('asking again', () {
    late _RecordingRehydrator rehydrator;

    setUp(() {
      rehydrator = _RecordingRehydrator();
      container.registerSingleton<SessionRehydrator>(rehydrator);
    });

    test('a read that failed is asked again on the next trigger', () async {
      remote.onFetchPage = (_, _) async => throw unreachable();
      final access = await install();
      await pumpEventQueue();

      remote.listing(const []);
      await rehydrator.rehydrateStale();

      expect(access.value.read, DataGatewayRead.granted);
    });

    test('a settled answer is not asked again', () async {
      remote.refusingReads();
      await install();
      await pumpEventQueue();

      await rehydrator.rehydrateStale();

      expect(remote.calls, hasLength(1));
    });
  });
}
