import 'package:models/domain.dart';
import 'package:test/test.dart';

ResourceAccess _access({
  AccessExtent create = AccessExtent.none,
  AccessExtent read = AccessExtent.none,
  AccessExtent update = AccessExtent.none,
  AccessExtent delete = AccessExtent.none,
  AccessExtent manage = AccessExtent.none,
}) => ResourceAccess(
  create: create,
  read: read,
  update: update,
  delete: delete,
  manage: manage,
);

void main() {
  group('CallerAccess', () {
    test('unknown allows nothing', () {
      const access = CallerAccess.unknown();

      expect(access.isKnown, isFalse);
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.read),
        isFalse,
      );
    });

    test('all and some allow, none does not', () {
      final access = CallerAccess.known({
        ResourceType.dataGateway: _access(
          read: AccessExtent.all,
          update: AccessExtent.some,
          delete: AccessExtent.none,
        ),
      });

      expect(access.isKnown, isTrue);
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.read),
        isTrue,
      );
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.update),
        isTrue,
      );
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.delete),
        isFalse,
      );
    });

    test('a type the answer lacks allows nothing', () {
      const access = CallerAccess.known({});

      expect(
        access.allows(ResourceType.dataGateway, AccessAction.read),
        isFalse,
      );
    });

    test('extentOf is none while unknown', () {
      expect(
        const CallerAccess.unknown().extentOf(
          ResourceType.household,
          AccessAction.read,
        ),
        AccessExtent.none,
      );
    });

    test('extentOf is none for a type the answer lacks', () {
      final access = CallerAccess.known({
        ResourceType.dataGateway: _access(read: AccessExtent.all),
      });

      expect(
        access.extentOf(ResourceType.household, AccessAction.read),
        AccessExtent.none,
      );
    });

    test('extentOf tells all from some', () {
      final some = CallerAccess.known({
        ResourceType.household: _access(read: AccessExtent.some),
      });
      final all = CallerAccess.known({
        ResourceType.household: _access(read: AccessExtent.all),
      });

      expect(
        some.extentOf(ResourceType.household, AccessAction.read),
        AccessExtent.some,
      );
      expect(
        all.extentOf(ResourceType.household, AccessAction.read),
        AccessExtent.all,
      );
    });

    test("household's wire name is the server's", () {
      expect(ResourceType.household.wireName, 'Household');
    });

    test('deniesEverything only when every action is none', () {
      expect(
        const CallerAccess.known({
          ResourceType.dataGateway: ResourceAccess.none,
        }).deniesEverything,
        isTrue,
      );
      expect(const CallerAccess.known({}).deniesEverything, isTrue);
      expect(
        CallerAccess.known({
          ResourceType.dataGateway: _access(manage: AccessExtent.some),
        }).deniesEverything,
        isFalse,
      );
      expect(const CallerAccess.unknown().deniesEverything, isFalse);
    });

    test('answers compare by value', () {
      expect(
        CallerAccess.known({
          ResourceType.dataGateway: _access(read: AccessExtent.all),
        }),
        CallerAccess.known({
          ResourceType.dataGateway: _access(read: AccessExtent.all),
        }),
      );
      expect(const CallerAccess.unknown(), const CallerAccess.unknown());
      expect(
        const CallerAccess.unknown() == const CallerAccess.known({}),
        isFalse,
      );
    });
  });
}
