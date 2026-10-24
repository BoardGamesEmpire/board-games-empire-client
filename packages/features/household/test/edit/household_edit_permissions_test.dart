import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';

Household _household({bool isLocalOnly = false}) => Household(
  id: 'hh_1',
  name: 'Den',
  isDirty: isLocalOnly,
  isLocalOnly: isLocalOnly,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

void main() {
  group('HouseholdEditPermissions.mayEdit', () {
    test('owners and admins may edit', () {
      expect(
        HouseholdEditPermissions.mayEdit(
          _household(),
          HouseholdRole.householdOwner,
        ),
        isTrue,
      );
      expect(
        HouseholdEditPermissions.mayEdit(
          _household(),
          HouseholdRole.householdAdmin,
        ),
        isTrue,
      );
    });

    test('members, guests, unknown and no role may not', () {
      for (final role in [
        HouseholdRole.householdMember,
        HouseholdRole.householdGuest,
        HouseholdRole.unknown,
        null,
      ]) {
        expect(
          HouseholdEditPermissions.mayEdit(_household(), role),
          isFalse,
          reason: '$role',
        );
      }
    });

    test('nobody edits a household the server has not confirmed', () {
      // Its edit would name an id the server never issued (#476).
      expect(
        HouseholdEditPermissions.mayEdit(
          _household(isLocalOnly: true),
          HouseholdRole.householdOwner,
        ),
        isFalse,
      );
    });
  });
}
