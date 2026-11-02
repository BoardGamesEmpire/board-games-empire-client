import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('AvailabilitySummary (#507)', () {
    OccurrenceAvailability tally(String occurrenceId) => OccurrenceAvailability(
      occurrenceId: occurrenceId,
      available: 1,
      maybe: 0,
      unavailable: 0,
      voters: const [],
    );

    test('of finds a date by its id, wherever the server listed it', () {
      final first = tally('o-1');
      final second = tally('o-2');
      final summary = AvailabilitySummary(occurrences: [first, second]);

      expect(summary.of('o-1'), same(first));
      expect(summary.of('o-2'), same(second));
    });

    test('of is null for a date the summary does not list', () {
      final summary = AvailabilitySummary(occurrences: [tally('o-1')]);

      expect(summary.of('o-9'), isNull);
    });

    test('a summary that says nothing of the roster does not withhold it', () {
      expect(AvailabilitySummary(occurrences: const []).rosterVisible, isTrue);
    });
  });
}
