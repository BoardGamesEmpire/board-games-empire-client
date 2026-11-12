import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  const wire = {
    'Open': NominationStatus.open,
    'AwaitingApproval': NominationStatus.awaitingApproval,
    'Approved': NominationStatus.approved,
    'Passed': NominationStatus.passed,
    'Failed': NominationStatus.failed,
    'QuorumNotMet': NominationStatus.quorumNotMet,
    'Rejected': NominationStatus.rejected,
    'Withdrawn': NominationStatus.withdrawn,
    'Paused': NominationStatus.paused,
  };

  group('NominationStatus', () {
    test('every wire name round-trips', () {
      for (final entry in wire.entries) {
        expect(NominationStatus.fromWire(entry.key), entry.value);
        expect(entry.value.toWire(), entry.key);
      }
    });

    test('an unknown name degrades to unknown', () {
      expect(NominationStatus.fromWire('Nope'), NominationStatus.unknown);
    });

    test('unknown has no wire name', () {
      expect(() => NominationStatus.unknown.toWire(), throwsStateError);
    });

    test('isLive is true for exactly open, awaitingApproval and paused', () {
      final live = {
        for (final s in NominationStatus.values)
          if (s.isLive) s,
      };
      expect(live, {
        NominationStatus.open,
        NominationStatus.awaitingApproval,
        NominationStatus.paused,
      });
    });

    test('inLineup is true for exactly approved and passed', () {
      final inLineup = {
        for (final s in NominationStatus.values)
          if (s.inLineup) s,
      };
      expect(inLineup, {NominationStatus.approved, NominationStatus.passed});
    });
  });
}
