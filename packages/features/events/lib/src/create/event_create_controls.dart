import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';

import 'event_link.dart';

/// The names of the event create form's controls (#499). The form is one
/// [FormGroup] across all its sections, built by [buildEventCreateForm].
abstract final class EventCreateControls {
  static const title = 'title',
      household = 'household',
      type = 'type',
      reach = 'reach',
      description = 'description',
      location = 'location',
      url = 'url',
      mode = 'mode',
      dates = 'dates',
      invitees = 'invitees',
      gameAddition = 'gameAddition',
      threshold = 'threshold',
      thresholdValue = 'thresholdValue',
      quorum = 'quorum',
      quorumValue = 'quorumValue',
      windowHours = 'windowHours';

  // Each row of [dates] is a group of these, built by [buildEventDateRow].
  static const start = 'start', end = 'end', label = 'label';
}

/// The errors the form's dates check sets (#499), beside reactive_forms'
/// [ValidationMessage.required] on a shown row's missing start.
abstract final class EventCreateErrors {
  /// On a shown row's end that comes before its start.
  static const endBeforeStart = 'endBeforeStart';

  /// The form's own error while its mode has too few dates, as several days
  /// and a poll take two. The mode control carries it too: that is where
  /// the section shows it, and what a refused submit can focus.
  ///
  /// Read it on the mode control. A group's `errors` file each child's
  /// errors under the child's name, so whenever a row has an error, the
  /// form's entry under this key is the dates' errors instead.
  static const tooFewDates = EventCreateControls.dates;

  /// On one of the rules' numbers that isn't a whole number its setting
  /// takes. Its value is the [WholeNumberRange] taken, for the message to
  /// name.
  static const wholeNumber = 'wholeNumber';

  /// On the link when it isn't a full one: an http or https link the
  /// server's own check takes. See [isFullLink].
  static const fullLink = 'fullLink';
}

/// The whole numbers one of the rules' numbers takes (#499): from `min`, up
/// to `max` where there is one.
typedef WholeNumberRange = ({int min, int? max});

/// The create form (#499): its basics; its mode, [EventSchedulingMode.fixed]
/// at first, and its dates, one empty row at first, checked against each
/// other; the people it invites, none at first; and its rules, untouched at
/// first, so the server's own apply.
///
/// The basics:
///
/// - The title is required. It is sent trimmed, so it is checked trimmed.
/// - The household, the type and who can see it start untouched, so the
///   event joins no household and takes the server's defaults.
/// - The description, the place and the link are optional. A link is
///   checked as the server checks it, so a link it would refuse is refused
///   here, before the create is queued: see [EventCreateErrors.fullLink].
///
/// The dates check is the group's, since it reads the mode. A row's start
/// and end are local times, as the pickers give them.
///
/// - One date shows and sends only the first row, so only that row is
///   checked: it needs a start. The rows another mode left behind are kept
///   for switching back, and an error on one would block a submit from a
///   field no one can see.
/// - Several days and a poll show and send every row: each needs a start,
///   and there have to be at least two.
/// - Every row shown has its end at or after its start. The server would
///   store one before it.
///
/// It sets and clears [ValidationMessage.required] on a row's start,
/// [EventCreateErrors.endBeforeStart] on its end and
/// [EventCreateErrors.tooFewDates] on the mode, so each shows where it is
/// fixed and a refused submit can focus it. A switch of mode checks every
/// row again.
///
/// The rules follow how games get added, the moment it changes:
///
/// - The voting settings (the threshold and quorum types, their numbers and
///   the voting window) are disabled unless attendees vote, and a number
///   unless its type takes one. reactive_forms leaves a disabled control out
///   of the form's validity, so a bad number left behind a setting no one
///   can see never blocks a submit. It is checked again when it shows again.
/// - Switching a threshold or quorum type starts its number over at that
///   type's default, so a number typed for one type is never read as
///   another's.
/// - Each number is a whole number in its type's range, or carries
///   [EventCreateErrors.wholeNumber]. The window may be left empty, for
///   voting the host closes.
FormGroup buildEventCreateForm() => FormGroup(
  {
    EventCreateControls.title: FormControl<String>(
      validators: [Validators.delegate(_checkTitle)],
    ),
    EventCreateControls.household: FormControl<String>(),
    EventCreateControls.type: FormControl<EventType>(),
    EventCreateControls.reach: FormControl<Reach>(),
    EventCreateControls.description: FormControl<String>(),
    EventCreateControls.location: FormControl<String>(),
    EventCreateControls.url: FormControl<String>(
      validators: [Validators.delegate(_checkLink)],
    ),
    EventCreateControls.mode: FormControl<EventSchedulingMode>(
      value: EventSchedulingMode.fixed,
    ),
    EventCreateControls.dates: FormArray<Map<String, Object?>>([
      buildEventDateRow(),
    ]),
    EventCreateControls.invitees: FormControl<List<UserSummary>>(
      value: const <UserSummary>[],
    ),
    ..._buildRules(),
  },
  validators: [Validators.delegate(_checkDates)],
);

/// One empty row of the form's dates: when it starts and ends, and its
/// label.
FormGroup buildEventDateRow() => FormGroup({
  EventCreateControls.start: FormControl<DateTime>(),
  EventCreateControls.end: FormControl<DateTime>(),
  EventCreateControls.label: FormControl<String>(),
});

/// The occurrences the form sends for its mode: one date sends only the
/// first row, and the others send every row in order.
///
/// Times go out in UTC. A label goes out only for several days, the one
/// mode that shows it: trimmed, and an empty one as none.
List<EventOccurrenceDraft> occurrencesOf(FormGroup form) {
  final mode = _controlOf<EventSchedulingMode>(
    form,
    EventCreateControls.mode,
  ).value;
  final rows = _datesOf(form).controls.cast<FormGroup>();
  final labelled = mode == EventSchedulingMode.multiDay;
  return [
    for (final row in showsEveryEventDate(mode) ? rows : rows.take(1))
      EventOccurrenceDraft(
        label: labelled
            ? trimmedOrNull(row.control(EventCreateControls.label).value)
            : null,
        startDate: (row.control(EventCreateControls.start).value as DateTime?)
            ?.toUtc(),
        endDate: (row.control(EventCreateControls.end).value as DateTime?)
            ?.toUtc(),
      ),
  ];
}

/// Whether [mode] shows and sends every row of the dates, as several days
/// and a poll do. One date shows and sends the first alone.
///
/// The one rule for the section, the check and [occurrencesOf], so a row
/// the form hides is never checked or sent.
bool showsEveryEventDate(EventSchedulingMode? mode) =>
    mode == EventSchedulingMode.multiDay || mode == EventSchedulingMode.poll;

/// The ids of the people the form invites, in the order they were picked.
List<String> inviteeIdsOf(FormGroup form) {
  final invitees = _controlOf<List<UserSummary>>(
    form,
    EventCreateControls.invitees,
  ).value;
  return [for (final user in invitees ?? const <UserSummary>[]) user.id];
}

/// The rules the form sends (#499), or null to leave them all to the
/// server.
///
/// - Null while how games get added is untouched or *Direct*, which is the
///   server's own default.
/// - Any other way is sent alone, but for a vote. A vote also sends its
///   threshold and quorum types, with a number for each type that takes
///   one, and the voting window when one is set: what
///   [EventDraft.checkSendable] expects of a draft.
///
/// Read it from a valid form, where each number is one its type takes. The
/// controls are read directly, since a disabled one is left out of the
/// form's value.
EventPolicyDraft? policyOf(FormGroup form) {
  final mode = _controlOf<GameAdditionMode>(
    form,
    EventCreateControls.gameAddition,
  ).value;
  if (mode == null || mode == GameAdditionMode.direct) return null;
  if (mode != GameAdditionMode.requiresVote) {
    return EventPolicyDraft(gameAdditionMode: mode);
  }

  final threshold = _controlOf<VoteThresholdType>(
    form,
    EventCreateControls.threshold,
  ).value;
  final quorum = _controlOf<VoteQuorumType>(
    form,
    EventCreateControls.quorum,
  ).value;
  int? numberIn(String name) =>
      _wholeNumberOf(_controlOf<String>(form, name).value);

  return EventPolicyDraft(
    gameAdditionMode: mode,
    voteThresholdType: threshold,
    voteThresholdValue: thresholdNumberOf(threshold) == null
        ? null
        : numberIn(EventCreateControls.thresholdValue),
    voteQuorumType: quorum,
    voteQuorumValue: quorumNumberOf(quorum) == null
        ? null
        : numberIn(EventCreateControls.quorumValue),
    votingWindowHours: numberIn(EventCreateControls.windowHours),
  );
}

/// The draft the form sends (#499): its basics trimmed, with an empty one
/// sent as none, and its dates, people and rules as [occurrencesOf],
/// [inviteeIdsOf] and [policyOf] send them. What is untouched is left out,
/// so the server's defaults apply.
///
/// Read it from a valid form, as those are.
EventDraft draftOf(FormGroup form) {
  String? text(String name) =>
      trimmedOrNull(_controlOf<String>(form, name).value);

  return EventDraft(
    title: text(EventCreateControls.title) ?? '',
    householdId: _controlOf<String>(form, EventCreateControls.household).value,
    description: text(EventCreateControls.description),
    location: text(EventCreateControls.location),
    url: text(EventCreateControls.url),
    type: _controlOf<EventType>(form, EventCreateControls.type).value,
    reach: _controlOf<Reach>(form, EventCreateControls.reach).value,
    schedulingMode:
        _controlOf<EventSchedulingMode>(form, EventCreateControls.mode).value ??
        EventSchedulingMode.fixed,
    occurrences: occurrencesOf(form),
    policy: policyOf(form),
    inviteUserIds: inviteeIdsOf(form),
  );
}

FormControl<T> _controlOf<T>(FormGroup form, String name) =>
    form.control(name) as FormControl<T>;

/// The dates, which [_controlOf] can't read: an array of rows, not one
/// control.
FormArray<Map<String, Object?>> _datesOf(FormGroup form) =>
    form.control(EventCreateControls.dates) as FormArray<Map<String, Object?>>;

/// [value] trimmed, or null where it is not text or blank once trimmed: a
/// field's value as the form and the date dialog (#506) send it.
String? trimmedOrNull(Object? value) {
  final trimmed = value is String ? value.trim() : '';
  return trimmed.isEmpty ? null : trimmed;
}

/// The group's dates check: see [buildEventCreateForm].
Map<String, dynamic>? _checkDates(AbstractControl<dynamic> control) {
  final form = control as FormGroup;
  final mode = _controlOf<EventSchedulingMode>(form, EventCreateControls.mode);
  final several = showsEveryEventDate(mode.value);
  final rows = _datesOf(form).controls.cast<FormGroup>();

  for (final (index, row) in rows.indexed) {
    final shown = several || index == 0;
    final start = row.control(EventCreateControls.start);
    final end = row.control(EventCreateControls.end);
    _flag(start, ValidationMessage.required, shown && start.value == null);
    checkEndBeforeStart(start, end, shown: shown);
  }

  final tooFew = rows.length < (several ? 2 : 1);
  _flag(mode, EventCreateErrors.tooFewDates, tooFew);
  return tooFew ? const {EventCreateErrors.tooFewDates: true} : null;
}

/// Sets [EventCreateErrors.endBeforeStart] on [end] while it comes before
/// [start], both set and [shown], and clears it once it doesn't. The dates
/// check runs it on each row, and the date dialog (#506) on its one.
void checkEndBeforeStart(
  AbstractControl<dynamic> start,
  AbstractControl<dynamic> end, {
  bool shown = true,
}) {
  final startsAt = start.value as DateTime?;
  final endsAt = end.value as DateTime?;
  _flag(
    end,
    EventCreateErrors.endBeforeStart,
    shown && startsAt != null && endsAt != null && endsAt.isBefore(startsAt),
  );
}

/// Sets or clears [error] on [control], leaving its other errors as they
/// are. Nothing changes, and nothing is emitted, when it already agrees.
///
/// A control's own validation clears what this sets whenever its value
/// changes, but that runs before the group's, so the group's check always
/// has the last word.
void _flag(AbstractControl<dynamic> control, String error, bool on) {
  if (control.hasError(error) == on) return;
  if (on) {
    control.setErrors({...control.errors, error: true}, markAsDirty: false);
  } else {
    control.removeError(error);
  }
}

/// [ValidationMessage.required] unless [control] holds more than whitespace.
Map<String, dynamic>? _checkTitle(AbstractControl<dynamic> control) =>
    trimmedOrNull(control.value) == null
    ? const {ValidationMessage.required: true}
    : null;

/// [EventCreateErrors.fullLink] unless [control] is empty or holds a full
/// link ([isFullLink]) once trimmed, as it is sent.
Map<String, dynamic>? _checkLink(AbstractControl<dynamic> control) {
  final link = trimmedOrNull(control.value);
  return link == null || isFullLink(link)
      ? null
      : const {EventCreateErrors.fullLink: true};
}

/// How games get added, and the voting settings that follow it: see
/// [buildEventCreateForm].
Map<String, AbstractControl<dynamic>> _buildRules() {
  final gameAddition = _Choice<GameAdditionMode>();
  final threshold = _Choice<VoteThresholdType>(
    value: VoteThresholdType.simpleMajority,
    disabled: true,
  );
  final quorum = _Choice<VoteQuorumType>(
    value: VoteQuorumType.none,
    disabled: true,
  );
  final thresholdValue = FormControl<String>(
    disabled: true,
    validators: [
      Validators.delegate(
        (control) => _checkWholeNumber(
          control,
          thresholdNumberOf(threshold.value)?.range,
        ),
      ),
    ],
  );
  final quorumValue = FormControl<String>(
    disabled: true,
    validators: [
      Validators.delegate(
        (control) =>
            _checkWholeNumber(control, quorumNumberOf(quorum.value)?.range),
      ),
    ],
  );
  final windowHours = FormControl<String>(
    disabled: true,
    validators: [
      Validators.delegate(
        (control) => _checkWholeNumber(control, _windowRange, optional: true),
      ),
    ],
  );

  // The voting settings show while attendees vote, and a number while its
  // type takes one.
  void follow() {
    final voting = gameAddition.value == GameAdditionMode.requiresVote;
    _enable(threshold, voting);
    _enable(quorum, voting);
    _enable(windowHours, voting);
    _enable(
      thresholdValue,
      voting && thresholdNumberOf(threshold.value) != null,
    );
    _enable(quorumValue, voting && quorumNumberOf(quorum.value) != null);
  }

  gameAddition.onChange = follow;
  threshold.onChange = () {
    _startOver(thresholdValue, thresholdNumberOf(threshold.value)?.start);
    follow();
  };
  quorum.onChange = () {
    _startOver(quorumValue, quorumNumberOf(quorum.value)?.start);
    follow();
  };

  return {
    EventCreateControls.gameAddition: gameAddition,
    EventCreateControls.threshold: threshold,
    EventCreateControls.thresholdValue: thresholdValue,
    EventCreateControls.quorum: quorum,
    EventCreateControls.quorumValue: quorumValue,
    EventCreateControls.windowHours: windowHours,
  };
}

/// A control others follow (#499): [onChange] runs the moment its value
/// changes, and only then.
///
/// Not a `valueChanges` listener: reactive_forms delivers those a microtask
/// later, so a submit could read the voting settings as they stood before
/// the switch, which is why feedback's compose form syncs its severity
/// where it is read.
class _Choice<T> extends FormControl<T> {
  _Choice({super.value, super.disabled});

  /// Set once the controls that follow it exist, so building it runs none.
  void Function()? onChange;

  @override
  void updateValue(
    T? value, {
    bool updateParent = true,
    bool emitEvent = true,
  }) {
    final changed = value != this.value;
    super.updateValue(value, updateParent: updateParent, emitEvent: emitEvent);
    if (changed) onChange?.call();
  }
}

/// The number a vote setting's type takes (#499): what it starts at, the
/// whole numbers it takes, and whether it is a share, in percent, rather
/// than a count.
typedef VoteSettingNumber = ({int start, WholeNumberRange range, bool percent});

/// The number a threshold of [type] takes, or null for one that takes none.
///
/// The one rule for which types take a number, and what kind: the form's
/// check and what it sends follow it, and so does the field the rules
/// section shows for it.
VoteSettingNumber? thresholdNumberOf(VoteThresholdType? type) => switch (type) {
  // A share of the votes cast, and more than half of them.
  VoteThresholdType.supermajority => (
    start: 66,
    range: (min: 51, max: 100),
    percent: true,
  ),
  VoteThresholdType.fixedCount => (
    start: 3,
    range: (min: 1, max: null),
    percent: false,
  ),
  VoteThresholdType.simpleMajority ||
  VoteThresholdType.unanimous ||
  VoteThresholdType.unknown ||
  null => null,
};

/// The number a quorum of [type] takes, or null for one that takes none.
/// The one rule for it, as [thresholdNumberOf] is for a threshold.
VoteSettingNumber? quorumNumberOf(VoteQuorumType? type) => switch (type) {
  // A share of the eligible voters.
  VoteQuorumType.percentOfAttendees => (
    start: 50,
    range: (min: 1, max: 100),
    percent: true,
  ),
  VoteQuorumType.fixedCount => (
    start: 3,
    range: (min: 1, max: null),
    percent: false,
  ),
  VoteQuorumType.none || VoteQuorumType.unknown || null => null,
};

/// The hours a vote stays open: any whole number of them, or none for
/// voting the host closes.
const WholeNumberRange _windowRange = (min: 1, max: null);

/// The largest number any of the rules takes. The server sets no top, but
/// it stores each in a Postgres integer: a larger number passes its checks,
/// then fails to store with a 500, which the queued create is retried for
/// until its attempts run out, so the event is never created.
const _largestNumber = 2147483647;

/// [EventCreateErrors.wholeNumber] unless [control] holds a whole number in
/// [range], when there is one. An empty one passes where [optional].
///
/// A range with no top names the largest number taken once it is passed.
Map<String, dynamic>? _checkWholeNumber(
  AbstractControl<dynamic> control,
  WholeNumberRange? range, {
  bool optional = false,
}) {
  if (range == null) return null;
  final text = (control.value as String?)?.trim() ?? '';
  if (optional && text.isEmpty) return null;

  final number = _wholeNumberOf(text);
  final max = range.max;
  if (number != null &&
      number >= range.min &&
      number <= (max ?? _largestNumber)) {
    return null;
  }
  // Digits too many for an int are past the largest too.
  final tooLarge =
      _digits.hasMatch(text) && (number == null || number > _largestNumber);
  return {
    EventCreateErrors.wholeNumber: (
      min: range.min,
      max: max ?? (tooLarge ? _largestNumber : null),
    ),
  };
}

/// The whole number [text] says once trimmed, or null when it says none.
/// Digits alone, so no sign, point or exponent: `int.parse` would take a
/// sign, and `0x` too.
int? _wholeNumberOf(String? text) {
  final trimmed = text?.trim() ?? '';
  return _digits.hasMatch(trimmed) ? int.tryParse(trimmed) : null;
}

final _digits = RegExp(r'^[0-9]+$');

/// Sets [number] to [start], and checks it against its new type even when
/// it held [start] already.
void _startOver(FormControl<String> number, int? start) {
  number.value = start?.toString();
  number.updateValueAndValidity();
}

void _enable(AbstractControl<dynamic> control, bool enabled) =>
    enabled ? control.markAsEnabled() : control.markAsDisabled();
