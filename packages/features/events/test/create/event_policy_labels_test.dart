import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_policy_labels.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

/// The words the create form's rules offer for each value (#499), and none
/// for a value this client can't read, which the form never offers.
void main() {
  final l10n = lookupEventsLocalizations(const Locale('en'));

  /// Checks that [label] gives each value in [expected] its words, and that
  /// it covers every value but `unknown`, which gets none.
  void names<T extends Enum>(
    List<T> values,
    String? Function(EventsLocalizations l10n, T value) label,
    Map<T, String> expected,
  ) {
    for (final value in values) {
      expect(
        label(l10n, value),
        value.name == 'unknown' ? isNull : expected[value],
        reason: '$value',
      );
    }
    expect(expected, hasLength(values.length - 1));
  }

  test('names each way games get added', () {
    names(GameAdditionMode.values, gameAdditionLabel, {
      GameAdditionMode.direct: 'Anyone attending adds them',
      GameAdditionMode.requiresVote: 'Attendees vote',
      GameAdditionMode.hostApproval: 'The host approves them',
      GameAdditionMode.hostOnly: 'Only hosts add them',
    });
  });

  test('names each vote threshold', () {
    names(VoteThresholdType.values, voteThresholdLabel, {
      VoteThresholdType.simpleMajority: 'More than half',
      VoteThresholdType.supermajority: 'A set share',
      VoteThresholdType.unanimous: 'Everyone',
      VoteThresholdType.fixedCount: 'A set number',
    });
  });

  test('names each quorum', () {
    names(VoteQuorumType.values, voteQuorumLabel, {
      VoteQuorumType.none: 'None',
      VoteQuorumType.percentOfAttendees: 'A share of attendees',
      VoteQuorumType.fixedCount: 'A set number',
    });
  });
}
