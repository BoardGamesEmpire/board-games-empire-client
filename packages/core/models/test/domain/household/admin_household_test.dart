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

    test('owners are equal by id, username and display name', () {
      final userId = ['u', '1'].join();
      final owner = AdminHouseholdOwner(
        userId: userId,
        username: 'ada',
        displayName: 'Ada L.',
      );

      expect(owner.props, ['u1', 'ada', 'Ada L.']);
      expect(
        owner,
        const AdminHouseholdOwner(
          userId: 'u1',
          username: 'ada',
          displayName: 'Ada L.',
        ),
      );
      expect(
        owner,
        isNot(AdminHouseholdOwner(userId: userId, username: 'ada')),
      );
      expect(
        owner,
        isNot(
          AdminHouseholdOwner(
            userId: userId,
            username: 'bea',
            displayName: 'Ada L.',
          ),
        ),
      );
    });
  });

  group('AdminHouseholdRow', () {
    final row = AdminHouseholdRow(
      id: 'h1',
      name: 'Catan Club',
      reach: Reach.private,
      createdAt: DateTime.utc(2026),
      deletedAt: DateTime.utc(2026, 2),
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
          createdAt: DateTime.utc(2026),
          memberCount: 3,
          owners: const [AdminHouseholdOwner(userId: 'u1', username: 'ada')],
        ),
      );
    });
  });

  group('AdminHouseholdDetail', () {
    final createdAt = DateTime.utc(2026);
    HouseholdMember member(String id) => HouseholdMember(
      id: id,
      userId: 'user_$id',
      householdId: 'h1',
      role: HouseholdRole.householdOwner,
      username: 'ada',
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    AdminHouseholdDetail detail({
      String id = 'h1',
      String name = 'Catan Club',
      String? description = 'Friday nights',
      String? image = 'https://example.test/i.png',
      Reach reach = Reach.friends,
      String? languageName = 'English',
      DateTime? created,
      List<HouseholdMember>? members,
    }) => AdminHouseholdDetail(
      id: id,
      name: name,
      description: description,
      image: image,
      reach: reach,
      languageName: languageName,
      createdAt: created ?? createdAt,
      members: members ?? [member('m1')],
    );

    test('keeps what it is given', () {
      final read = detail();

      expect(read.id, 'h1');
      expect(read.name, 'Catan Club');
      expect(read.description, 'Friday nights');
      expect(read.image, 'https://example.test/i.png');
      expect(read.reach, Reach.friends);
      expect(read.languageName, 'English');
      expect(read.createdAt, createdAt);
      expect(read.members, [member('m1')]);
    });

    test('details are equal by every field, the roster included', () {
      expect(detail(), detail());
      expect(detail().hashCode, detail().hashCode);
      expect(detail(), isNot(detail(id: 'h2')));
      expect(detail(), isNot(detail(name: 'Ticket Club')));
      expect(detail(), isNot(detail(description: null)));
      expect(detail(), isNot(detail(image: null)));
      expect(detail(), isNot(detail(reach: Reach.private)));
      expect(
        detail(),
        isNot(detail(created: createdAt.add(const Duration(days: 1)))),
      );
      expect(detail(), isNot(detail(languageName: null)));
      expect(detail(), isNot(detail(members: [member('m2')])));
      expect(detail(), isNot(detail(members: const [])));
    });
  });
}
