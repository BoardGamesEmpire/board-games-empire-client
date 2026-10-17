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
    await const DataGatewayAccessInstaller(refusalRecheckDelay: Duration.zero)
        .install(container, _server(), 'user-1');
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

  group('a 403 is asked once more before it settles', () {
    // The server writes a new user's roles after sign-up answers, so a read
    // sent straight after it is refused even for the server's first owner
    // (backend#490).
    test('so an owner refused before their roles landed is let in', () async {
      final second = Completer<PaginatedResult<DataGateway>>();
      var reads = 0;
      remote.onFetchPage = (_, _) =>
          ++reads == 1 ? Future.error(forbidden()) : second.future;

      final access = await install();
      await pumpEventQueue();

      expect(remote.calls, hasLength(2));
      expect(access.value.read, DataGatewayRead.unknown);

      second.complete(pageOf(const []));
      await pumpEventQueue();

      expect(access.value.read, DataGatewayRead.granted);
    });

    test('and a second 403 settles it', () async {
      remote.refusingReads();

      final access = await install();
      await pumpEventQueue();

      expect(remote.calls, hasLength(2));
      expect(access.value.read, DataGatewayRead.denied);
    });

    test('unless a screen answered meanwhile', () async {
      final second = Completer<PaginatedResult<DataGateway>>();
      var reads = 0;
      remote.onFetchPage = (_, _) =>
          ++reads == 1 ? Future.error(forbidden()) : second.future;
      final access = await install();
      await pumpEventQueue();

      access.readGranted();
      second.completeError(forbidden());
      await pumpEventQueue();

      expect(access.value.read, DataGatewayRead.granted);
    });

    test('and not once the session has ended', () async {
      final first = Completer<PaginatedResult<DataGateway>>();
      remote.onFetchPage = (_, _) => first.future;
      final access = DataGatewayAccess(
        remote: remote,
        refusalRecheckDelay: Duration.zero,
      );

      final checking = access.check();
      access.dispose();
      first.completeError(forbidden());
      await checking;

      expect(remote.calls, hasLength(1));
    });
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

  group('a screen that reads while the check is in flight', () {
    late Completer<PaginatedResult<DataGateway>> pending;

    setUp(() {
      pending = Completer<PaginatedResult<DataGateway>>();
      remote.onFetchPage = (_, _) => pending.future;
    });

    test('keeps its grant over the check refused before it, as when a role '
        'was raised meanwhile', () async {
      final access = await install();

      access.readGranted();
      pending.completeError(forbidden());
      await pumpEventQueue();

      expect(access.value.read, DataGatewayRead.granted);
    });

    test('keeps its refusal over the check granted before it, as when a role '
        'was lowered meanwhile', () async {
      final access = await install();

      access.readDenied();
      pending.complete(pageOf(const []));
      await pumpEventQueue();

      expect(access.value.read, DataGatewayRead.denied);
    });
  });

  test('a check started after a screen read answers for itself', () async {
    remote.refusingReads();
    final access = await install();
    await pumpEventQueue();
    access.readGranted();

    await access.check();

    expect(access.value.read, DataGatewayRead.denied);
  });

  test('registers nothing where no DataGateway client is reachable', () async {
    final bare = DependencyContainerImpl();
    addTearDown(bare.dispose);

    await const DataGatewayAccessInstaller().install(bare, _server(), 'user-1');

    expect(bare.isRegistered<DataGatewayAccess>(), isFalse);
  });

  test('waits two seconds before asking a 403 again', () {
    expect(
      const DataGatewayAccessInstaller().refusalRecheckDelay,
      const Duration(seconds: 2),
    );
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
      final settledAfter = remote.calls.length;

      await rehydrator.rehydrateStale();

      expect(remote.calls, hasLength(settledAfter));
    });
  });
}
