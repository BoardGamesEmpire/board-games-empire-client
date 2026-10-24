import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('HouseholdUpdate', () {
    test('a blank name is refused', () {
      expect(() => HouseholdUpdate(name: ' \n\t '), throwsArgumentError);
    });

    test('a description and a clear are refused together', () {
      expect(
        () =>
            HouseholdUpdate(description: 'Board games', clearDescription: true),
        throwsArgumentError,
      );
    });

    test('an unknown policy is refused', () {
      // It stands for a name this client could not read, so it has no wire
      // name to send.
      expect(
        () => HouseholdUpdate(memberInvitePolicy: MemberInvitePolicy.unknown),
        throwsArgumentError,
      );
    });

    test('a name is stored trimmed', () {
      expect(HouseholdUpdate(name: '  Den ').name, 'Den');
    });

    test('an update that changes nothing is empty', () {
      expect(HouseholdUpdate().isEmpty, isTrue);
      expect(HouseholdUpdate(name: 'Den').isEmpty, isFalse);
      expect(HouseholdUpdate(description: 'Board games').isEmpty, isFalse);
      expect(HouseholdUpdate(clearDescription: true).isEmpty, isFalse);
      expect(
        HouseholdUpdate(memberInvitePolicy: MemberInvitePolicy.off).isEmpty,
        isFalse,
      );
    });
  });
}
