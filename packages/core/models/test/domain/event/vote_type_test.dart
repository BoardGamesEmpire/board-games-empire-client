import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('VoteType', () {
    test('every wire name round-trips', () {
      const wire = {
        'For': VoteType.forGame,
        'Against': VoteType.against,
        'Interested': VoteType.interested,
      };
      for (final entry in wire.entries) {
        expect(VoteType.fromWire(entry.key), entry.value);
        expect(entry.value.toWire(), entry.key);
      }
    });

    test('an unknown name degrades to unknown', () {
      expect(VoteType.fromWire('Nope'), VoteType.unknown);
    });

    test('unknown has no wire name', () {
      expect(() => VoteType.unknown.toWire(), throwsStateError);
    });
  });
}
