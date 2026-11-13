import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('GameOfferRefusal', () {
    test('every wire value resolves', () {
      const wire = {
        'notFound': GameOfferRefusal.notFound,
        'notInAttendeesCollection': GameOfferRefusal.notInAttendeesCollection,
        'removedFromCollection': GameOfferRefusal.removedFromCollection,
        'notAnExpansionOfBase': GameOfferRefusal.notAnExpansionOfBase,
        'baseRefused': GameOfferRefusal.baseRefused,
      };
      for (final entry in wire.entries) {
        expect(GameOfferRefusal.fromWire(entry.key), entry.value);
      }
    });

    test('an unknown value degrades to unknown', () {
      expect(
        GameOfferRefusal.fromWire('somethingNew'),
        GameOfferRefusal.unknown,
      );
    });
  });
}
