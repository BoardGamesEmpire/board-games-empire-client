import 'package:events/src/create/event_create_controls.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';

/// The edit form (#500), filled in from [event] and, when [rulesEditable],
/// its rules [policy]: the create form's basics and rules, under the same
/// names, built by the same [buildEventBasicsControls] and
/// [buildEventRulesControls], so the two forms check the same way.
///
/// - Each text opens as stored, whitespace and all. It is trimmed when read
///   ([editValuesOf]) and compared trimmed ([eventUpdateOf]), so whitespace
///   another client stored is no change.
/// - A type or reach this app doesn't know opens empty, and an empty one is
///   never sent, so the event keeps it.
/// - With rules this form can't show ([rulesEditable]), it has no rules
///   controls at all, and saves none.
/// - A rule's number that still holds what the server stores, under the
///   type it is stored with, passes its range check, and so does a voting
///   window that still holds the stored one. The server takes numbers the
///   form's own ranges don't, such as a 40% share where the form starts at
///   51%, and only a change is sent, so one left as it is never goes back:
///   checked, it would stop a save of anything else. A number the user
///   changes, or one under a type they changed, is checked as on the create
///   form, and so is one the server stores none of: an empty number under a
///   type that takes one has no stored value to keep.
///
/// It has no household, dates or people: the event can't move household
/// here, and its dates and invitees are edited elsewhere (#506, #511).
FormGroup buildEventEditForm(Event event, EventPolicy? policy) {
  final editable = rulesEditable(policy);
  final form = FormGroup({
    ...buildEventBasicsControls(),
    if (editable) ...buildEventRulesControls(),
  });

  void fill<T>(String name, T? value) => controlOf<T>(form, name).value = value;

  fill(EventCreateControls.title, event.title);
  fill(EventCreateControls.type, _known(event.type, EventType.unknown));
  fill(EventCreateControls.reach, _known(event.reach, Reach.unknown));
  fill(EventCreateControls.description, event.description);
  fill(EventCreateControls.location, event.location);
  fill(EventCreateControls.url, event.url);

  if (editable && policy != null) {
    // Before the numbers are filled in, so each is checked as it lands.
    _passStored(
      controlOf<String>(form, EventCreateControls.thresholdValue),
      policy.voteThresholdValue,
      type: controlOf<VoteThresholdType>(form, EventCreateControls.threshold),
      storedType: policy.voteThresholdType,
    );
    _passStored(
      controlOf<String>(form, EventCreateControls.quorumValue),
      policy.voteQuorumValue,
      type: controlOf<VoteQuorumType>(form, EventCreateControls.quorum),
      storedType: policy.voteQuorumType,
    );
    _passStored(
      controlOf<String>(form, EventCreateControls.windowHours),
      policy.votingWindowHours,
    );

    // In this order: setting a type to another starts its number over at
    // the type's default, so each number is set after its type, or an
    // untouched form would send that default.
    fill(EventCreateControls.gameAddition, policy.gameAdditionMode);
    fill(EventCreateControls.threshold, policy.voteThresholdType);
    fill(EventCreateControls.thresholdValue, _text(policy.voteThresholdValue));
    fill(EventCreateControls.quorum, policy.voteQuorumType);
    fill(EventCreateControls.quorumValue, _text(policy.voteQuorumValue));
    fill(EventCreateControls.windowHours, _text(policy.votingWindowHours));
  }
  return form;
}

/// Lets [number] through its checks while it holds [stored], as the form
/// shows it, and [type], for a number that belongs to one, holds
/// [storedType]. Anything else is checked by the checks it was built with,
/// and so is everything when nothing is [stored]. See
/// [buildEventEditForm].
///
/// Read when the number is checked, which a switch of its type starts, so
/// a type switched back starts its number over and is checked again.
void _passStored(
  FormControl<String> number,
  int? stored, {
  AbstractControl<Object?>? type,
  Object? storedType,
}) {
  // A copy: the control's list is a view, which the next line empties.
  final check = Validators.compose([...number.validators]);
  number.setValidators([
    Validators.delegate(
      (control) =>
          stored != null &&
              (type == null || type.value == storedType) &&
              trimmedOrNull(control.value) == _text(stored)
          ? null
          : check(control),
    ),
  ]);
}

/// Whether the edit form can show and change [policy]: not when there is
/// none, as for a viewer under the read ceiling, nor when how games get
/// added or a vote setting is one this app doesn't know.
///
/// A rule the form can't show would be sent back as something else, or a
/// change built against it could undo what it holds (#500).
bool rulesEditable(EventPolicy? policy) =>
    policy != null &&
    policy.gameAdditionMode != GameAdditionMode.unknown &&
    policy.voteThresholdType != VoteThresholdType.unknown &&
    policy.voteQuorumType != VoteQuorumType.unknown;

/// What the edit form holds (#500), read by [editValuesOf], for
/// [eventUpdateOf] and [policyUpdateOf] to compare with the event the form
/// opened with.
///
/// Its text is held trimmed, and a blank one as null, however it was given.
@immutable
final class EventEditValues {
  EventEditValues({
    required String title,
    String? description,
    String? location,
    String? url,
    this.type,
    this.reach,
    this.rules,
  }) : title = title.trim(),
       description = trimmedOrNull(description),
       location = trimmedOrNull(location),
       url = trimmedOrNull(url);

  /// Empty only on a form that isn't valid, which has no title to send.
  final String title;
  final String? description;
  final String? location;
  final String? url;

  /// Null while the menu is empty, as for a type this app doesn't know.
  final EventType? type;

  /// Null while the menu is empty, as for a reach this app doesn't know.
  final Reach? reach;

  /// The rules as [rulesOf] reads them, or null when the form has none to
  /// edit.
  final EventPolicyDraft? rules;

  /// These values with no rules, for a viewer who can't change them: an
  /// edit with them sends none.
  EventEditValues withoutRules() => EventEditValues(
    title: title,
    description: description,
    location: location,
    url: url,
    type: type,
    reach: reach,
  );

  @override
  bool operator ==(Object other) =>
      other is EventEditValues &&
      other.title == title &&
      other.description == description &&
      other.location == location &&
      other.url == url &&
      other.type == type &&
      other.reach == reach &&
      other.rules == rules;

  @override
  int get hashCode =>
      Object.hash(title, description, location, url, type, reach, rules);
}

/// What the edit form [form] holds: its basics, and its rules where it has
/// rules controls, as [rulesOf] reads them. How games get added is always
/// there, and the vote settings only under a vote, each number only where
/// its type takes one.
///
/// Read it from a valid form, as [rulesOf] is. The controls are read
/// directly, since a disabled one is left out of the form's value.
EventEditValues editValuesOf(FormGroup form) => EventEditValues(
  title: controlOf<String>(form, EventCreateControls.title).value ?? '',
  description: controlOf<String>(form, EventCreateControls.description).value,
  location: controlOf<String>(form, EventCreateControls.location).value,
  url: controlOf<String>(form, EventCreateControls.url).value,
  type: controlOf<EventType>(form, EventCreateControls.type).value,
  reach: controlOf<Reach>(form, EventCreateControls.reach).value,
  rules: form.contains(EventCreateControls.gameAddition) ? rulesOf(form) : null,
);

/// A field an edit can send: the event's own, which [EventUpdate] carries,
/// then its rules', which [EventPolicyUpdate] carries.
///
/// A save remembers the fields a failed send may have written anyway, and
/// sends each again until a save lands (`resend`).
enum EventEditField {
  title,
  description,
  location,
  url,
  type,
  reach,
  gameAdditionMode,
  voteThresholdType,
  voteThresholdValue,
  voteQuorumType,
  voteQuorumValue,
  votingWindowHours,
}

/// What [values] changes on the event's own fields, as [original] has them
/// (#500).
///
/// With no version check on the server, a field sent unchanged would
/// overwrite whatever another device saved since, so only what changed is
/// sent:
///
/// - A text is sent when it differs from the original's, both trimmed, with
///   null and blank alike as empty. Whitespace another client stored is no
///   change.
/// - An empty description, place or link that is sent is its clear.
/// - A type or reach is sent when it differs. An empty one never is, so one
///   this app doesn't know stays as it is.
///
/// A field in [resend] is sent even when unchanged: a failed save may have
/// written it, so the original may no longer describe it. The title is
/// never sent empty, since the event must keep one.
EventUpdate eventUpdateOf(
  Event original,
  EventEditValues values, {
  Set<EventEditField> resend = const {},
}) {
  final title = trimmedOrNull(values.title);
  final sendTitle =
      title != null &&
      _sends(
        resend,
        EventEditField.title,
        title,
        trimmedOrNull(original.title),
      );
  final sendDescription = _sends(
    resend,
    EventEditField.description,
    values.description,
    trimmedOrNull(original.description),
  );
  final sendLocation = _sends(
    resend,
    EventEditField.location,
    values.location,
    trimmedOrNull(original.location),
  );
  final sendUrl = _sends(
    resend,
    EventEditField.url,
    values.url,
    trimmedOrNull(original.url),
  );
  final type = _known(values.type, EventType.unknown);
  final reach = _known(values.reach, Reach.unknown);

  return EventUpdate(
    title: sendTitle ? title : null,
    description: sendDescription ? values.description : null,
    clearDescription: sendDescription && values.description == null,
    location: sendLocation ? values.location : null,
    clearLocation: sendLocation && values.location == null,
    url: sendUrl ? values.url : null,
    clearUrl: sendUrl && values.url == null,
    type:
        type != null && _sends(resend, EventEditField.type, type, original.type)
        ? type
        : null,
    reach:
        reach != null &&
            _sends(resend, EventEditField.reach, reach, original.reach)
        ? reach
        : null,
  );
}

/// What [rules] changes on the event's rules, as [original] has them
/// (#500), sent only where it changed, as [eventUpdateOf] sends the event's.
///
/// A field is sent when [rules] carries it and it differs from the
/// original's, or when it is in [resend]:
///
/// - How games get added is always carried.
/// - The vote settings are carried only under a vote, and each number only
///   where its type takes one ([thresholdNumberOf], [quorumNumberOf]). One
///   not carried is never sent, even in [resend]: the server keeps it,
///   unused.
/// - A type that is sent takes its number with it, changed or not. The
///   number is a share under one type and a count under another, and the
///   server's may be another device's since the page opened.
/// - The window, under a vote, is carried even when empty. An empty one
///   that is sent is its clear, so one the original had is cleared, and
///   one it never had is cleared only when resent.
///
/// Only what the update takes is sent. A valid form gives nothing else, but
/// an empty type or number, an `unknown` choice or a number below 1 is left
/// out rather than sent.
EventPolicyUpdate policyUpdateOf(
  EventPolicy original,
  EventPolicyDraft rules, {
  Set<EventEditField> resend = const {},
}) {
  T? sent<T>(EventEditField field, T? value, T? before) =>
      value != null && _sends(resend, field, value, before) ? value : null;
  // A type that is sent carries its number, changed or not.
  int? sentNumber(
    EventEditField field,
    int? value,
    int? before, {
    required bool typeSent,
  }) => value == null || value < 1
      ? null
      : typeSent
      ? value
      : sent(field, value, before);

  final mode = _known(rules.gameAdditionMode, GameAdditionMode.unknown);
  final voting = mode == GameAdditionMode.requiresVote;
  final threshold = voting
      ? _known(rules.voteThresholdType, VoteThresholdType.unknown)
      : null;
  final quorum = voting
      ? _known(rules.voteQuorumType, VoteQuorumType.unknown)
      : null;
  final window = rules.votingWindowHours;
  final sendWindow =
      voting &&
      (window == null || window >= 1) &&
      _sends(
        resend,
        EventEditField.votingWindowHours,
        window,
        original.votingWindowHours,
      );

  final thresholdType = sent(
    EventEditField.voteThresholdType,
    threshold,
    original.voteThresholdType,
  );
  final quorumType = sent(
    EventEditField.voteQuorumType,
    quorum,
    original.voteQuorumType,
  );

  return EventPolicyUpdate(
    gameAdditionMode: sent(
      EventEditField.gameAdditionMode,
      mode,
      original.gameAdditionMode,
    ),
    voteThresholdType: thresholdType,
    voteThresholdValue: thresholdNumberOf(threshold) == null
        ? null
        : sentNumber(
            EventEditField.voteThresholdValue,
            rules.voteThresholdValue,
            original.voteThresholdValue,
            typeSent: thresholdType != null,
          ),
    voteQuorumType: quorumType,
    voteQuorumValue: quorumNumberOf(quorum) == null
        ? null
        : sentNumber(
            EventEditField.voteQuorumValue,
            rules.voteQuorumValue,
            original.voteQuorumValue,
            typeSent: quorumType != null,
          ),
    votingWindowHours: sendWindow ? window : null,
    clearVotingWindowHours: sendWindow && window == null,
  );
}

/// The event's fields [update] sends, a clear included: the ones a failed
/// send may have written.
Set<EventEditField> fieldsSentBy(EventUpdate update) => {
  if (update.title != null) EventEditField.title,
  if (update.description != null || update.clearDescription)
    EventEditField.description,
  if (update.location != null || update.clearLocation) EventEditField.location,
  if (update.url != null || update.clearUrl) EventEditField.url,
  if (update.type != null) EventEditField.type,
  if (update.reach != null) EventEditField.reach,
};

/// The rules' fields [update] sends, a cleared window included: the ones a
/// failed send may have written.
Set<EventEditField> rulesFieldsSentBy(EventPolicyUpdate update) => {
  if (update.gameAdditionMode != null) EventEditField.gameAdditionMode,
  if (update.voteThresholdType != null) EventEditField.voteThresholdType,
  if (update.voteThresholdValue != null) EventEditField.voteThresholdValue,
  if (update.voteQuorumType != null) EventEditField.voteQuorumType,
  if (update.voteQuorumValue != null) EventEditField.voteQuorumValue,
  if (update.votingWindowHours != null || update.clearVotingWindowHours)
    EventEditField.votingWindowHours,
};

/// Whether [field] is sent, as [value] where it was [before]: when it
/// changed, or when it is in [resend], changed or not. The one rule for
/// [eventUpdateOf] and [policyUpdateOf].
bool _sends(
  Set<EventEditField> resend,
  EventEditField field,
  Object? value,
  Object? before,
) => resend.contains(field) || value != before;

/// [value], or null where it is [unknown]: a value from a newer server,
/// which has no label to show and nothing to send.
T? _known<T extends Enum>(T? value, T unknown) =>
    value == unknown ? null : value;

/// [number] as its field shows it, or null for none.
String? _text(int? number) => number?.toString();
