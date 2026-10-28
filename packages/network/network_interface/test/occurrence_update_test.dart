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
  });
}
