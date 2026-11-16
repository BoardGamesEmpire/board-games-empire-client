import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';

/// `ServerRepositoryKnownServerLookup` maps a link's `bgeServerId` to the
/// registry's device-local `ServerConfig.id` via
/// [ServerRepository.getServerByBgeId], independent of connection state.
class _MockServerRepository extends Mock implements ServerRepository {}

class _FakeServerConfig extends Fake implements ServerConfig {
  _FakeServerConfig({required this.id, required this.connectionState});

  @override
  final String id;

  @override
  final ConnectionState connectionState;
}

void main() {
  late _MockServerRepository repository;
  late ServerRepositoryKnownServerLookup lookup;

  setUp(() {
    repository = _MockServerRepository();
    lookup = ServerRepositoryKnownServerLookup(serverRepository: repository);
  });

  group('ServerRepositoryKnownServerLookup', () {
    test(
      "localServerIdFor returns the registered config's id for its "
      'bgeServerId',
      () async {
        when(() => repository.getServerByBgeId('bge-1')).thenAnswer(
          (_) async => _FakeServerConfig(
            id: 'local-1',
            connectionState: ConnectionState.active,
          ),
        );

        await expectLater(
          lookup.localServerIdFor('bge-1'),
          completion('local-1'),
        );
        verify(() => repository.getServerByBgeId('bge-1')).called(1);
      },
    );

    test(
      'localServerIdFor returns null for an unregistered bgeServerId',
      () async {
        when(() => repository.getServerByBgeId('bge-unknown'))
            .thenAnswer((_) async => null);

        await expectLater(
          lookup.localServerIdFor('bge-unknown'),
          completion(isNull),
        );
      },
    );

    test('localServerIdFor answers a disconnected server too', () async {
      when(() => repository.getServerByBgeId('bge-2')).thenAnswer(
        (_) async => _FakeServerConfig(
          id: 'local-2',
          connectionState: ConnectionState.disconnected,
        ),
      );

      await expectLater(
        lookup.localServerIdFor('bge-2'),
        completion('local-2'),
      );
    });
  });
}
