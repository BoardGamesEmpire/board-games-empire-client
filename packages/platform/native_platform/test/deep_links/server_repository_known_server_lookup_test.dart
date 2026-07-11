import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';

/// `ServerRepositoryKnownServerLookup` — *known* is strictly
/// MetaDB registry membership via [ServerRepository.getServer] (the source
/// of truth per the #10 decision), independent of connection state.
class _MockServerRepository extends Mock implements ServerRepository {}

class _FakeServerConfig extends Fake implements ServerConfig {}

void main() {
  late _MockServerRepository repository;
  late ServerRepositoryKnownServerLookup lookup;

  setUp(() {
    repository = _MockServerRepository();
    lookup = ServerRepositoryKnownServerLookup(serverRepository: repository);
  });

  group('ServerRepositoryKnownServerLookup', () {
    test('a registered serverId is known', () async {
      when(
        () => repository.getServer('known-id'),
      ).thenAnswer((_) async => _FakeServerConfig());

      await expectLater(lookup.isKnownServer('known-id'), completion(isTrue));
      verify(() => repository.getServer('known-id')).called(1);
    });

    test('an unregistered serverId is not known', () async {
      when(
        () => repository.getServer('unknown-id'),
      ).thenAnswer((_) async => null);

      await expectLater(
        lookup.isKnownServer('unknown-id'),
        completion(isFalse),
      );
      verify(() => repository.getServer('unknown-id')).called(1);
    });
  });
}
