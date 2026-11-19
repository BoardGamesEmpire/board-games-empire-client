import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/edit/event_edit_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';

final _at = DateTime.utc(2026, 11, 18);

/// An event with every basic set.
Event _event({
  String title = 'Game night',
  String? description = 'Bring snacks',
  String? location = 'The back room',
  String? url = 'https://example.com/night',
  EventType type = EventType.strategyNight,
  Reach reach = Reach.friends,
}) => Event(
  id: 'ev_1',
  title: title,
  createdById: 'u_host',
  type: type,
  reach: reach,
  status: EventStatus.scheduled,
  schedulingMode: EventSchedulingMode.fixed,
  createdAt: _at,
  updatedAt: _at,
  description: description,
  location: location,
  url: url,
);

/// A voting policy: a supermajority of 75, a quorum of 40% of attendees and
/// a 48-hour window, unless told otherwise.
EventPolicy _policy({
  GameAdditionMode mode = GameAdditionMode.requiresVote,
  VoteThresholdType threshold = VoteThresholdType.supermajority,
  int? thresholdValue = 75,
  VoteQuorumType quorum = VoteQuorumType.percentOfAttendees,
  int? quorumValue = 40,
  int? window = 48,
}) => EventPolicy(
  id: 'p_1',
  eventId: 'ev_1',
  allowMemberInvites: true,
  allowGuestInvites: false,
  restrictToGameCategories: false,
  requireHostApprovalToJoin: false,
  allowSpectators: false,
  strictCapacity: false,
  gameAdditionMode: mode,
  restrictToAttendeePool: false,
  voteThresholdType: threshold,
  voteThresholdValue: thresholdValue,
  voteQuorumType: quorum,
  voteQuorumValue: quorumValue,
  votingWindowHours: window,
  voteEligibility: VoteEligibility.allAttendees,
  interestedWeight: InterestedWeight.asAbstain,
  createdAt: _at,
  updatedAt: _at,
);

/// The server's own rules for a new event: anyone attending adds games, and
/// the vote settings behind them are its defaults.
final EventPolicy _direct = _policy(
  mode: GameAdditionMode.direct,
  threshold: VoteThresholdType.simpleMajority,
  thresholdValue: null,
  quorum: VoteQuorumType.none,
  quorumValue: null,
  window: null,
);

const List<String> _rulesControls = [
  EventCreateControls.gameAddition,
  EventCreateControls.threshold,
  EventCreateControls.thresholdValue,
  EventCreateControls.quorum,
  EventCreateControls.quorumValue,
  EventCreateControls.windowHours,
];

/// Pins the edit form's controls (#500): what [buildEventEditForm] opens
/// with, what [editValuesOf] reads back, and what [eventUpdateOf] and
/// [policyUpdateOf] send of it.
void main() {
  test('an untouched form changes nothing', () {
    final event = _event();
    final policy = _policy();
    final form = buildEventEditForm(event, policy);

    expect(form.valid, isTrue);
    final values = editValuesOf(form);
    expect(eventUpdateOf(event, values).isEmpty, isTrue);
    expect(policyUpdateOf(policy, values.rules!).isEmpty, isTrue);
  });

  test('a stored supermajority opens at its own value, not the default', () {
    final form = buildEventEditForm(_event(), _policy());

    // Set before its type, the number would have started over at 66.
    final value = controlOf<String>(form, EventCreateControls.thresholdValue);
    expect(value.value, '75');
    expect(value.enabled, isTrue);
    expect(
      controlOf<String>(form, EventCreateControls.quorumValue).value,
      '40',
    );
  });

  test("unknown type and reach open empty and aren't sent", () {
    final event = _event(type: EventType.unknown, reach: Reach.unknown);
    final form = buildEventEditForm(event, _policy());

    expect(controlOf<EventType>(form, EventCreateControls.type).value, isNull);
    expect(controlOf<Reach>(form, EventCreateControls.reach).value, isNull);
    expect(form.valid, isTrue);
    expect(eventUpdateOf(event, editValuesOf(form)).isEmpty, isTrue);
  });

  test('whitespace around a stored value is not a change', () {
    final event = _event(title: '  Game night ');
    final form = buildEventEditForm(event, _policy());
    final title = controlOf<String>(form, EventCreateControls.title);

    // Opened as stored.
    expect(title.value, '  Game night ');
    expect(eventUpdateOf(event, editValuesOf(form)).isEmpty, isTrue);

    title.value = 'Game night';
    expect(eventUpdateOf(event, editValuesOf(form)).isEmpty, isTrue);
  });

  test('a cleared description, place and link are clears', () {
    final event = _event();
    final form = buildEventEditForm(event, _policy());
    for (final name in [
      EventCreateControls.description,
      EventCreateControls.location,
      EventCreateControls.url,
    ]) {
      controlOf<String>(form, name).value = '';
    }

    expect(form.valid, isTrue);
    final update = eventUpdateOf(event, editValuesOf(form));
    expect(update.clearDescription, isTrue);
    expect(update.clearLocation, isTrue);
    expect(update.clearUrl, isTrue);
    expect(
      update,
      EventUpdate(clearDescription: true, clearLocation: true, clearUrl: true),
    );
  });

  test('a changed title is sent trimmed', () {
    final event = _event();
    final form = buildEventEditForm(event, _policy());
    controlOf<String>(form, EventCreateControls.title).value =
        "  Games at Ana's  ";

    expect(form.valid, isTrue);
    expect(
      eventUpdateOf(event, editValuesOf(form)),
      EventUpdate(title: "Games at Ana's"),
    );
  });

  test('resend sends an unchanged field', () {
    final event = _event();
    final unchanged = editValuesOf(buildEventEditForm(event, _policy()));

    expect(eventUpdateOf(event, unchanged).isEmpty, isTrue);
    final update = eventUpdateOf(
      event,
      unchanged,
      resend: {EventEditField.title},
    );
    expect(update.title, event.title);
    expect(update, EventUpdate(title: event.title));
  });

  test('a known reach changed to another is sent', () {
    final event = _event();
    final form = buildEventEditForm(event, _policy());
    controlOf<Reach>(form, EventCreateControls.reach).value = Reach.public;

    expect(form.valid, isTrue);
    expect(
      eventUpdateOf(event, editValuesOf(form)),
      EventUpdate(reach: Reach.public),
    );
  });

  test('resend sends an unchanged vote setting the rules carry', () {
    final policy = _policy();
    final rules = editValuesOf(buildEventEditForm(_event(), policy)).rules!;

    expect(policyUpdateOf(policy, rules).isEmpty, isTrue);
    expect(
      policyUpdateOf(
        policy,
        rules,
        resend: {EventEditField.voteThresholdType},
      ),
      // Its number goes with it.
      EventPolicyUpdate(
        voteThresholdType: VoteThresholdType.supermajority,
        voteThresholdValue: 75,
      ),
    );
  });

  test('a changed vote type carries its number, though it is unchanged', () {
    // 75 means a share under one type and a count under the other, and
    // the server's number may be another device's since the page opened.
    const rules = EventPolicyDraft(
      gameAdditionMode: GameAdditionMode.requiresVote,
      voteThresholdType: VoteThresholdType.fixedCount,
      voteThresholdValue: 75,
      voteQuorumType: VoteQuorumType.fixedCount,
      voteQuorumValue: 40,
      votingWindowHours: 48,
    );

    expect(
      policyUpdateOf(_policy(), rules),
      EventPolicyUpdate(
        voteThresholdType: VoteThresholdType.fixedCount,
        voteThresholdValue: 75,
        voteQuorumType: VoteQuorumType.fixedCount,
        voteQuorumValue: 40,
      ),
    );
  });

  test('a changed number carries its type, though it is unchanged', () {
    // The server keeps a type left out, and it may be another device's
    // since the page opened: 80 typed as a share would land as a count.
    const rules = EventPolicyDraft(
      gameAdditionMode: GameAdditionMode.requiresVote,
      voteThresholdType: VoteThresholdType.supermajority,
      voteThresholdValue: 80,
      voteQuorumType: VoteQuorumType.percentOfAttendees,
      voteQuorumValue: 50,
      votingWindowHours: 48,
    );

    expect(
      policyUpdateOf(_policy(), rules),
      EventPolicyUpdate(
        voteThresholdType: VoteThresholdType.supermajority,
        voteThresholdValue: 80,
        voteQuorumType: VoteQuorumType.percentOfAttendees,
        voteQuorumValue: 50,
      ),
    );
  });

  test('resend of a number alone carries its type', () {
    final policy = _policy();
    final rules = editValuesOf(buildEventEditForm(_event(), policy)).rules!;

    expect(
      policyUpdateOf(
        policy,
        rules,
        resend: {EventEditField.voteQuorumValue},
      ),
      EventPolicyUpdate(
        voteQuorumType: VoteQuorumType.percentOfAttendees,
        voteQuorumValue: 40,
      ),
    );
  });

  group("a stored number the form's own ranges refuse", () {
    // The server took each of these, and the form takes none of them: a
    // share from 51, a turnout up to 100, a window from 1.
    EventPolicy stored() =>
        _policy(thresholdValue: 40, quorumValue: 150, window: 0);

    FormControl<String> numberOf(FormGroup form, String name) =>
        controlOf<String>(form, name);

    test('passes while it is left as stored, and is not sent', () {
      final event = _event();
      final policy = stored();
      final form = buildEventEditForm(event, policy);

      for (final name in [
        EventCreateControls.thresholdValue,
        EventCreateControls.quorumValue,
        EventCreateControls.windowHours,
      ]) {
        expect(numberOf(form, name).valid, isTrue, reason: name);
      }
      expect(form.valid, isTrue);

      controlOf<String>(form, EventCreateControls.title).value = 'Board night';
      final values = editValuesOf(form);
      expect(eventUpdateOf(event, values), EventUpdate(title: 'Board night'));
      expect(policyUpdateOf(policy, values.rules!).isEmpty, isTrue);
    });

    test('is checked once changed, and passes again put back', () {
      final form = buildEventEditForm(_event(), stored());
      final share = numberOf(form, EventCreateControls.thresholdValue)
        ..value = '45';

      expect(share.errors[EventCreateErrors.wholeNumber], (min: 51, max: 100));
      expect(form.valid, isFalse);

      share.value = '40';
      expect(share.valid, isTrue);

      final window = numberOf(form, EventCreateControls.windowHours)
        ..value = '00';
      expect(window.errors[EventCreateErrors.wholeNumber], (min: 1, max: null));
    });

    test('under a newly chosen type is checked', () {
      // A count of 40 votes, which the form takes.
      final form = buildEventEditForm(
        _event(),
        _policy(threshold: VoteThresholdType.fixedCount, thresholdValue: 40),
      );
      final share = numberOf(form, EventCreateControls.thresholdValue);
      expect(share.valid, isTrue);

      controlOf<VoteThresholdType>(form, EventCreateControls.threshold).value =
          VoteThresholdType.supermajority;
      share.value = '40';

      expect(share.errors[EventCreateErrors.wholeNumber], (min: 51, max: 100));
      expect(form.valid, isFalse);
    });

    test('none stored, under a type that takes one, is checked', () {
      // The server holds a supermajority with no share behind direct adds.
      final form = buildEventEditForm(
        _event(),
        _policy(mode: GameAdditionMode.direct, thresholdValue: null),
      );
      controlOf<GameAdditionMode>(
        form,
        EventCreateControls.gameAddition,
      ).value = GameAdditionMode.requiresVote;
      final share = numberOf(form, EventCreateControls.thresholdValue);

      expect(share.value, isNull);
      expect(share.valid, isFalse);
      expect(form.valid, isFalse);
    });

    test('no window stored and none now passes', () {
      final form = buildEventEditForm(_event(), _policy(window: null));

      expect(numberOf(form, EventCreateControls.windowHours).valid, isTrue);
      expect(form.valid, isTrue);
    });

    test("the create form's checks are unchanged", () {
      final form = buildEventCreateForm();
      controlOf<GameAdditionMode>(
        form,
        EventCreateControls.gameAddition,
      ).value = GameAdditionMode.requiresVote;
      controlOf<VoteThresholdType>(form, EventCreateControls.threshold).value =
          VoteThresholdType.supermajority;
      final share = numberOf(form, EventCreateControls.thresholdValue)
        ..value = '40';

      expect(share.errors[EventCreateErrors.wholeNumber], (min: 51, max: 100));
    });
  });

  test('switching from direct to a vote sends the mode and the vote '
      'settings', () {
    final form = buildEventEditForm(_event(), _direct);
    controlOf<GameAdditionMode>(form, EventCreateControls.gameAddition).value =
        GameAdditionMode.requiresVote;
    controlOf<VoteThresholdType>(form, EventCreateControls.threshold).value =
        VoteThresholdType.supermajority;
    controlOf<String>(form, EventCreateControls.thresholdValue).value = '70';
    controlOf<VoteQuorumType>(form, EventCreateControls.quorum).value =
        VoteQuorumType.fixedCount;
    controlOf<String>(form, EventCreateControls.quorumValue).value = '4';
    controlOf<String>(form, EventCreateControls.windowHours).value = '24';

    expect(form.valid, isTrue);
    expect(
      policyUpdateOf(_direct, editValuesOf(form).rules!),
      EventPolicyUpdate(
        gameAdditionMode: GameAdditionMode.requiresVote,
        voteThresholdType: VoteThresholdType.supermajority,
        voteThresholdValue: 70,
        voteQuorumType: VoteQuorumType.fixedCount,
        voteQuorumValue: 4,
        votingWindowHours: 24,
      ),
    );
  });

  test('switching from a vote to host approval sends only the mode', () {
    final policy = _policy();
    final form = buildEventEditForm(_event(), policy);
    controlOf<GameAdditionMode>(form, EventCreateControls.gameAddition).value =
        GameAdditionMode.hostApproval;

    expect(form.valid, isTrue);
    expect(
      policyUpdateOf(policy, editValuesOf(form).rules!),
      EventPolicyUpdate(gameAdditionMode: GameAdditionMode.hostApproval),
    );
  });

  test('emptying the window under a vote clears it', () {
    final policy = _policy();
    final form = buildEventEditForm(_event(), policy);
    controlOf<String>(form, EventCreateControls.windowHours).value = '';

    expect(form.valid, isTrue);
    final update = policyUpdateOf(policy, editValuesOf(form).rules!);
    expect(update.clearVotingWindowHours, isTrue);
    expect(update, EventPolicyUpdate(clearVotingWindowHours: true));
  });

  test('a policy with an unknown mode is not editable', () {
    final policy = _policy(mode: GameAdditionMode.unknown);

    expect(rulesEditable(policy), isFalse);
    final form = buildEventEditForm(_event(), policy);
    expect(form.contains(EventCreateControls.gameAddition), isFalse);
    expect(editValuesOf(form).rules, isNull);

    // So is one with a vote setting this app doesn't know.
    expect(
      rulesEditable(_policy(threshold: VoteThresholdType.unknown)),
      isFalse,
    );
    expect(rulesEditable(_policy(quorum: VoteQuorumType.unknown)), isFalse);
    expect(rulesEditable(_policy()), isTrue);
  });

  test('no policy, no rules controls', () {
    expect(rulesEditable(null), isFalse);
    final form = buildEventEditForm(_event(), null);

    for (final name in _rulesControls) {
      expect(form.contains(name), isFalse, reason: name);
    }
    expect(form.valid, isTrue);
    expect(editValuesOf(form).rules, isNull);
  });

  group('what is never sent', () {
    test('the edit form has no household, dates or invitees', () {
      final form = buildEventEditForm(_event(), _policy());

      for (final name in [
        EventCreateControls.household,
        EventCreateControls.mode,
        EventCreateControls.dates,
        EventCreateControls.invitees,
      ]) {
        expect(form.contains(name), isFalse, reason: name);
      }
    });

    test('a vote setting the rules no longer carry is not sent, even when '
        'resent', () {
      final policy = _policy();
      final form = buildEventEditForm(_event(), policy);
      controlOf<GameAdditionMode>(
        form,
        EventCreateControls.gameAddition,
      ).value = GameAdditionMode.hostApproval;

      expect(
        policyUpdateOf(
          policy,
          editValuesOf(form).rules!,
          resend: EventEditField.values.toSet(),
        ),
        EventPolicyUpdate(gameAdditionMode: GameAdditionMode.hostApproval),
      );
    });

    test('a number its type no longer takes is not sent', () {
      final policy = _policy();
      final form = buildEventEditForm(_event(), policy);
      controlOf<VoteThresholdType>(form, EventCreateControls.threshold).value =
          VoteThresholdType.simpleMajority;
      controlOf<VoteQuorumType>(form, EventCreateControls.quorum).value =
          VoteQuorumType.none;

      expect(form.valid, isTrue);
      expect(
        policyUpdateOf(
          policy,
          editValuesOf(form).rules!,
          resend: {
            EventEditField.voteThresholdValue,
            EventEditField.voteQuorumValue,
          },
        ),
        EventPolicyUpdate(
          voteThresholdType: VoteThresholdType.simpleMajority,
          voteQuorumType: VoteQuorumType.none,
        ),
      );
    });

    test('the vote settings behind another mode open as stored', () {
      final policy = _policy(mode: GameAdditionMode.hostApproval);
      final form = buildEventEditForm(_event(), policy);
      final value = controlOf<String>(form, EventCreateControls.thresholdValue);

      // Hidden, but as the server holds them.
      expect((value.value, value.disabled), ('75', true));

      controlOf<GameAdditionMode>(
        form,
        EventCreateControls.gameAddition,
      ).value = GameAdditionMode.requiresVote;
      expect((value.value, value.enabled), ('75', true));
      expect(form.valid, isTrue);
      expect(
        policyUpdateOf(policy, editValuesOf(form).rules!),
        EventPolicyUpdate(gameAdditionMode: GameAdditionMode.requiresVote),
      );
    });

    test('no window before and none now clears nothing, unless resent', () {
      final policy = _policy(window: null);
      final rules = editValuesOf(buildEventEditForm(_event(), policy)).rules!;

      expect(rules.votingWindowHours, isNull);
      expect(policyUpdateOf(policy, rules).isEmpty, isTrue);
      expect(
        policyUpdateOf(
          policy,
          rules,
          resend: {EventEditField.votingWindowHours},
        ),
        EventPolicyUpdate(clearVotingWindowHours: true),
      );
    });

    test('an empty type or reach is not sent, even when resent', () {
      final event = _event(type: EventType.unknown, reach: Reach.unknown);
      final form = buildEventEditForm(event, null);

      expect(
        eventUpdateOf(
          event,
          editValuesOf(form),
          resend: {EventEditField.type, EventEditField.reach},
        ).isEmpty,
        isTrue,
      );

      // A known one picked in its place is sent.
      controlOf<EventType>(form, EventCreateControls.type).value =
          EventType.familyNight;
      expect(
        eventUpdateOf(event, editValuesOf(form)),
        EventUpdate(type: EventType.familyNight),
      );
    });

    test('a resent empty description, place or link is its clear', () {
      final event = _event(description: null, location: '  ', url: null);
      final values = editValuesOf(buildEventEditForm(event, null));

      expect(eventUpdateOf(event, values).isEmpty, isTrue);
      expect(
        eventUpdateOf(
          event,
          values,
          resend: {
            EventEditField.description,
            EventEditField.location,
            EventEditField.url,
          },
        ),
        EventUpdate(
          clearDescription: true,
          clearLocation: true,
          clearUrl: true,
        ),
      );
    });

    test('what only an invalid form holds is not sent', () {
      // The page saves only a valid form. Read from one that isn't, nothing
      // the update would throw on is sent.
      final event = _event();
      final policy = _policy();
      final form = buildEventEditForm(event, policy);
      controlOf<String>(form, EventCreateControls.title).value = '   ';
      controlOf<String>(form, EventCreateControls.thresholdValue).value = '0';
      controlOf<String>(form, EventCreateControls.quorumValue).value = '';

      expect(form.valid, isFalse);
      final values = editValuesOf(form);
      expect(eventUpdateOf(event, values).isEmpty, isTrue);
      expect(policyUpdateOf(policy, values.rules!).isEmpty, isTrue);
    });
  });

  group('EventEditValues', () {
    test('holds its text trimmed, a blank as none, and compares by value', () {
      final values = EventEditValues(
        title: ' Game night ',
        description: '  ',
        location: ' The back room ',
        url: '',
        type: EventType.familyNight,
        rules: const EventPolicyDraft(
          gameAdditionMode: GameAdditionMode.hostOnly,
        ),
      );

      expect(values.title, 'Game night');
      expect(values.description, isNull);
      expect(values.location, 'The back room');
      expect(values.url, isNull);
      expect(
        values,
        EventEditValues(
          title: 'Game night',
          location: 'The back room',
          type: EventType.familyNight,
          rules: const EventPolicyDraft(
            gameAdditionMode: GameAdditionMode.hostOnly,
          ),
        ),
      );
      expect(
        values,
        isNot(EventEditValues(title: 'Game night', location: 'The back room')),
      );
    });
  });

  group('fieldsSentBy and rulesFieldsSentBy', () {
    test('name each field an update sends, a clear included', () {
      expect(fieldsSentBy(EventUpdate()), isEmpty);
      expect(
        fieldsSentBy(
          EventUpdate(
            title: 'Game night',
            clearDescription: true,
            location: 'The back room',
            clearUrl: true,
            type: EventType.familyNight,
            reach: Reach.public,
          ),
        ),
        {
          EventEditField.title,
          EventEditField.description,
          EventEditField.location,
          EventEditField.url,
          EventEditField.type,
          EventEditField.reach,
        },
      );
      expect(
        fieldsSentBy(EventUpdate(description: 'Bring snacks', clearUrl: true)),
        {EventEditField.description, EventEditField.url},
      );

      expect(rulesFieldsSentBy(EventPolicyUpdate()), isEmpty);
      expect(
        rulesFieldsSentBy(
          EventPolicyUpdate(
            gameAdditionMode: GameAdditionMode.requiresVote,
            voteThresholdType: VoteThresholdType.fixedCount,
            voteThresholdValue: 3,
            voteQuorumType: VoteQuorumType.fixedCount,
            voteQuorumValue: 2,
            votingWindowHours: 24,
          ),
        ),
        {
          EventEditField.gameAdditionMode,
          EventEditField.voteThresholdType,
          EventEditField.voteThresholdValue,
          EventEditField.voteQuorumType,
          EventEditField.voteQuorumValue,
          EventEditField.votingWindowHours,
        },
      );
      expect(
        rulesFieldsSentBy(EventPolicyUpdate(clearVotingWindowHours: true)),
        {EventEditField.votingWindowHours},
      );
    });
  });
}
