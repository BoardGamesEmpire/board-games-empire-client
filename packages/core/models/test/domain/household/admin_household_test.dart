import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('AdminHouseholdSort.allowedWith', () {
    test('deleted sort needs deleted rows', () {
      expect(
        AdminHouseholdSort.deleted.allowedWith(AdminHouseholdStatus.live),
        isFalse,
      );
      expect(
        AdminHouseholdSort.deleted.allowedWith(AdminHouseholdStatus.deleted),
        isTrue,
      );
      expect(
        AdminHouseholdSort.deleted.allowedWith(AdminHouseholdStatus.all),
        isTrue,
      );
      for (final sort in AdminHouseholdSort.values.where(
        (s) => s != AdminHouseholdSort.deleted,
      )) {
        for (final status in AdminHouseholdStatus.values) {
          expect(sort.allowedWith(status), isTrue, reason: '$sort $status');
        }
      }
    });

    test('wire names are the enum names', () {
      expect(AdminHouseholdSort.newest.wireName, 'newest');
      expect(AdminHouseholdStatus.deleted.wireName, 'deleted');
    });
  });

  group('AdminHouseholdOwner', () {
    test('an owner without a display name is named by username', () {
      for (final displayName in <String?>[null, '']) {
        final owner = AdminHouseholdOwner(
          userId: 'u1',
          username: 'ada',
          displayName: displayName,
        );
        expect(owner.name, 'ada');
      }
      const named = AdminHouseholdOwner(
        userId: 'u1',
        username: 'ada',
        displayName: 'Ada L.',
      );
      expect(named.name, 'Ada L.');
    });

    test('an owner with no name to show has none', () {
      const blank = AdminHouseholdOwner(
        userId: 'u1',
        username: ' ',
        displayName: '',
      );
      expect(blank.name, isNull);
    });
  });

  group('AdminHouseholdRow', () {
    final row = AdminHouseholdRow(
      id: 'h1',
      name: 'Catan Club',
      reach: Reach.private,
      createdAt: DateTime.utc(2026, 1, 1),
      deletedAt: DateTime.utc(2026, 2, 1),
      memberCount: 3,
      owners: const [AdminHouseholdOwner(userId: 'u1', username: 'ada')],
    );

    test('restored clears deletedAt and keeps the rest', () {
      expect(row.isDeleted, isTrue);
      final restored = row.restored();
      expect(restored.isDeleted, isFalse);
      expect(restored.deletedAt, isNull);
      expect(
        restored,
        AdminHouseholdRow(
          id: 'h1',
          name: 'Catan Club',
          reach: Reach.private,
          createdAt: DateTime.utc(2026, 1, 1),
          memberCount: 3,
          owners: const [AdminHouseholdOwner(userId: 'u1', username: 'ada')],
        ),
      );
    });
  });
}
