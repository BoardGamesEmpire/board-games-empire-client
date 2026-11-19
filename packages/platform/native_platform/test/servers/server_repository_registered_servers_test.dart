import 'dart:async';

import 'package:bge_test_support/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';

/// `ServerRepositoryRegisteredServers` lists the MetaDB server registry via
/// [ServerRepository.watchServers], independent of connection state, and
/// drops a repeat of the last list because drift's `watch` does not.
class _MockServerRepository extends Mock implements ServerRepository {}

ServerConfig _server(String id, ConnectionState state) => ServerConfig(
  id: id,
  displayName: 'Server $id',
  serverUrl: testServerUrl,
  connectionState: state,
  bgeServerId: 'bge-$id',
  cachedIdentity: testServerIdentity(),
  lastIdentityFetchedAt: DateTime.utc(2026, 11, 17),
);

void main() {
  late _MockServerRepository repository;
  late ServerRepositoryRegisteredServers registered;

  setUp(() {
    repository = _MockServerRepository();
    registered = ServerRepositoryRegisteredServers(
      serverRepository: repository,
    );
  });

  group('ServerRepositoryRegisteredServers', () {
    test(
      'watch lists every registered server, disconnected ones too',
      () async {
        final servers = [
          _server('a', ConnectionState.active),
          _server('b', ConnectionState.disconnected),
          _server('c', ConnectionState.backgrounding),
        ];
        when(() => repository.watchServers())
            .thenAnswer((_) => Stream.value(servers));

        await expectLater(registered.watch(), emits(servers));
      },
    );

    test('watch drops an emission equal to the last', () async {
      final controller = StreamController<List<ServerConfig>>();
      addTearDown(controller.close);
      when(() => repository.watchServers())
          .thenAnswer((_) => controller.stream);
      final emitted = <List<ServerConfig>>[];
      final subscription = registered.watch().listen(emitted.add);
      addTearDown(subscription.cancel);

      final one = [_server('a', ConnectionState.active)];
      final two = [
        _server('a', ConnectionState.active),
        _server('b', ConnectionState.disconnected),
      ];
      controller
        ..add(one)
        ..add([_server('a', ConnectionState.active)])
        ..add(two);
      await pumpEventQueue();

      expect(emitted, [one, two]);
    });
  });
}
