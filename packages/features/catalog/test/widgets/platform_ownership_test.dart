import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/widgets/platform_ownership.dart';
import 'package:models/domain.dart';

void main() {
  PlatformGame platform(String id, String name, [PlatformType? type]) =>
      PlatformGame(
        id: id,
        gameId: 'g_catan',
        platformId: 'plat_$id',
        platformName: name,
        platformType: type,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

  GameCollection entry(
    String platformGameId,
    GameMedium medium, {
    DateTime? deletedAt,
  }) => GameCollection(
    id: 'e_${platformGameId}_${medium.name}',
    userId: 'u_1',
    platformGameId: platformGameId,
    medium: medium,
    deletedAt: deletedAt,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  final tabletop = platform('pg_1', 'Tabletop');
  final steam = platform('pg_2', 'Steam');

  test('an entry marked for removal is not owned', () {
    final ownership = PlatformOwnership.of(
      platformGames: [tabletop, steam],
      entries: [
        entry('pg_1', GameMedium.physical, deletedAt: DateTime.utc(2026, 2)),
        entry('pg_2', GameMedium.digital),
      ],
    );

    expect(ownership.owns('pg_1'), isFalse);
    expect(ownership.entriesOn('pg_1'), isEmpty);
    expect(ownership.owns('pg_2'), isTrue);
    expect(ownership.entriesOn('pg_2'), [entry('pg_2', GameMedium.digital)]);
    // The removed copy's medium is free again.
    expect(
      ownership.addOptions.first,
      CollectionAddOption(
        platformGame: tabletop,
        freeMediums: {GameMedium.physical, GameMedium.digital},
      ),
    );
  });

  test('addOptions keeps a platform with one medium owned, offering the '
      'other', () {
    final ownership = PlatformOwnership.of(
      platformGames: [tabletop, steam],
      entries: [entry('pg_1', GameMedium.physical)],
    );

    expect(ownership.addOptions, [
      CollectionAddOption(
        platformGame: tabletop,
        freeMediums: {GameMedium.digital},
      ),
      CollectionAddOption(
        platformGame: steam,
        freeMediums: {GameMedium.physical, GameMedium.digital},
      ),
    ]);
  });

  test('addOptions is empty when every platform is owned in both '
      'mediums', () {
    final ownership = PlatformOwnership.of(
      platformGames: [tabletop, steam],
      entries: [
        entry('pg_1', GameMedium.physical),
        entry('pg_1', GameMedium.digital),
        entry('pg_2', GameMedium.digital),
        entry('pg_2', GameMedium.physical),
      ],
    );

    expect(ownership.addOptions, isEmpty);
    expect(ownership.entriesOn('pg_1'), hasLength(2));
  });

  // A digital edition of a board game is its own listing on another platform
  // (#797), so a Tabletop platform never offers Digital.
  group('a Tabletop platform', () {
    final board = platform('pg_3', 'Tabletop', PlatformType.tabletop);

    test('a Tabletop platform offers Physical only', () {
      final ownership = PlatformOwnership.of(
        platformGames: [board],
        entries: const [],
      );

      expect(ownership.addOptions.single.freeMediums, {GameMedium.physical});
    });

    test('a Tabletop platform owned as Physical has nothing to add', () {
      final ownership = PlatformOwnership.of(
        platformGames: [board],
        entries: [entry('pg_3', GameMedium.physical)],
      );

      expect(ownership.addOptions, isEmpty);
      expect(ownership.owns('pg_3'), isTrue);
    });

    test('a Tabletop platform owned only as Digital still offers '
        'Physical', () {
      final ownership = PlatformOwnership.of(
        platformGames: [board],
        entries: [entry('pg_3', GameMedium.digital)],
      );

      expect(ownership.addOptions.single.freeMediums, {GameMedium.physical});
      expect(ownership.owns('pg_3'), isTrue);
    });
  });

  test('an unknown or missing type keeps both mediums', () {
    for (final type in [PlatformType.unknown, null]) {
      final ownership = PlatformOwnership.of(
        platformGames: [platform('pg_4', 'Other', type)],
        entries: const [],
      );

      expect(
        ownership.addOptions.single.freeMediums,
        {GameMedium.physical, GameMedium.digital},
        reason: '$type',
      );
    }
  });
}
