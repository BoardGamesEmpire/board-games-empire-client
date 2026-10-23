import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('PlatformType', () {
    test('every Prisma PlatformType value has a Dart binding', () {
      // Mirrors prisma/models/game/platform.prisma at backend a21cd51e.
      const serverValues = <String, PlatformType>{
        'Tabletop': PlatformType.tabletop,
        'Console': PlatformType.console,
        'Portable': PlatformType.portable,
        'PC': PlatformType.pc,
        'Mobile': PlatformType.mobile,
        'Arcade': PlatformType.arcade,
        'Other': PlatformType.other,
      };

      for (final entry in serverValues.entries) {
        expect(PlatformType.fromWire(entry.key), entry.value);
        expect(entry.value.toWire(), entry.key);
      }
    });

    test('a name this client does not know reads as unknown', () {
      expect(PlatformType.fromWire('Hologram'), PlatformType.unknown);
    });

    test('unknown has no wire name, so it is never sent', () {
      expect(PlatformType.unknown.toWire, throwsStateError);
    });
  });
}
