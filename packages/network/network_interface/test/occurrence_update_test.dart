import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('OccurrenceUpdate', () {
    test('is equal by its fields', () {
      // The bloc event that carries it compares by its props (#506).
      final start = DateTime.utc(2026, 11, 6, 19);
      expect(
        OccurrenceUpdate(label: 'Day 1', startDate: start, clearEndDate: true),
        OccurrenceUpdate(
          label: ' Day 1 ',
          startDate: start,
          clearEndDate: true,
        ),
      );
      expect(
        OccurrenceUpdate(label: 'Day 1').hashCode,
        OccurrenceUpdate(label: 'Day 1').hashCode,
      );
      expect(
        OccurrenceUpdate(label: 'Day 1'),
        isNot(OccurrenceUpdate(location: 'Day 1')),
      );
    });

    test('a blank value is refused', () {
      expect(() => OccurrenceUpdate(label: '  '), throwsArgumentError);
      expect(() => OccurrenceUpdate(location: ''), throwsArgumentError);
    });

    test('a value and its own clear flag are refused together', () {
      // The PATCH cannot send both.
      expect(
        () => OccurrenceUpdate(label: 'Day 1', clearLabel: true),
        throwsArgumentError,
      );
      expect(
        () => OccurrenceUpdate(endDate: DateTime.utc(2026), clearEndDate: true),
        throwsArgumentError,
      );
      expect(
        () => OccurrenceUpdate(location: 'Hall', clearLocation: true),
        throwsArgumentError,
      );
    });

    test('an update that changes nothing is empty', () {
      expect(OccurrenceUpdate().isEmpty, isTrue);
      expect(OccurrenceUpdate(label: 'Day 1').isEmpty, isFalse);
      expect(OccurrenceUpdate(clearLabel: true).isEmpty, isFalse);
      expect(OccurrenceUpdate(startDate: DateTime.utc(2026)).isEmpty, isFalse);
      expect(OccurrenceUpdate(endDate: DateTime.utc(2026)).isEmpty, isFalse);
      expect(OccurrenceUpdate(clearEndDate: true).isEmpty, isFalse);
      expect(OccurrenceUpdate(location: 'Hall').isEmpty, isFalse);
      expect(OccurrenceUpdate(clearLocation: true).isEmpty, isFalse);
    });
  });
}
