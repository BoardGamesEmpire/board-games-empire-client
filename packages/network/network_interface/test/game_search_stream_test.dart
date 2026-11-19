import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('GameSearchProgress (#473)', () {
    const catan = GameSearchHit(
      externalId: 'g_catan',
      title: 'Catan',
      contentType: ContentType.baseGame,
      gameId: 'g_catan',
    );

    // Built at run time, so no two are the same instance, nor their results.
    GameSearchProgress progress({
      bool localDone = true,
      bool done = true,
      bool cutShort = false,
    }) => GameSearchProgress(
      results: GameSearchResults(local: [catan.copyWith()]),
      localDone: localDone,
      done: done,
      cutShort: cutShort,
    );

    test('is not cut short unless it says so', () {
      const answer = GameSearchProgress(
        results: GameSearchResults(),
        localDone: false,
        done: false,
      );

      expect(answer.cutShort, isFalse);
    });

    test('is equal by its fields', () {
      expect(progress(), progress());
      expect(progress().hashCode, progress().hashCode);
      expect(progress(), isNot(progress(localDone: false)));
      expect(progress(), isNot(progress(done: false)));
      expect(progress(), isNot(progress(cutShort: true)));
      expect(
        progress(),
        isNot(
          const GameSearchProgress(
            results: GameSearchResults(),
            localDone: true,
            done: true,
          ),
        ),
      );
    });
  });
}
