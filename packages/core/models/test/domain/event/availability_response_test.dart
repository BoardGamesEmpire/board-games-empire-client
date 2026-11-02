import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('AvailabilityResponse (#507)', () {
    test('each wire name reads as its value and writes back', () {
      const wire = {
        'Available': AvailabilityResponse.available,
        'Maybe': AvailabilityResponse.maybe,
        'Unavailable': AvailabilityResponse.unavailable,
      };

      for (final entry in wire.entries) {
        expect(AvailabilityResponse.fromWire(entry.key), entry.value);
        expect(entry.value.toWire(), entry.key);
      }
      // A value added to the enum without a wire name fails here, instead of
      // reading as `unknown` through the switch's fall-through arm.
      expect(
        wire.values.toSet(),
        AvailabilityResponse.values
            .where((value) => value != AvailabilityResponse.unknown)
            .toSet(),
      );
    });

    test('a name this client does not know reads as unknown', () {
      expect(
        AvailabilityResponse.fromWire('Sometimes'),
        AvailabilityResponse.unknown,
      );
    });

    test('unknown has no wire name', () {
      expect(() => AvailabilityResponse.unknown.toWire(), throwsStateError);
    });
  });
}
