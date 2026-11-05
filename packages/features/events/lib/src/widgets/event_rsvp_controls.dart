import 'dart:async';

import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../screens/event_detail_screen.dart';
import 'event_labels.dart';

/// The viewer's own answer to an event's invitation (#508): Going, Maybe and
/// Not going as one named group of chips, with their answer selected, and a
/// button for the note that goes with it.
///
/// Invited has no chip: it is where a row starts, not an answer. A note goes
/// out with the current answer, and an answer this client doesn't know has
/// no name to send, so there is no note button while the answer is one.
///
/// Each control is a direct write, so offline each is disabled, and one note
/// under the group says why (#49).
///
/// ## Held through a write
///
/// One request goes out at a time. The controls remember a press, and ignore
/// any other until they forget it, one inside the same frame included. While
/// they are unavailable after it, through its write ([busy]) and the read
/// that write's outcome starts (not [enabled]), its control stays enabled
/// and ignores presses, and the others are disabled. A disabled
/// control can't hold focus, so one disabled under its own press would drop a
/// keyboard or screen-reader user's place (#607). Its node keeps its selected
/// state, reading as not enabled with no tap, and its name says why: a chip
/// whose answer is on its way names it as being saved, and the note button
/// says its note is.
///
/// The press is forgotten the first time the controls are built available
/// after its write went out, and as soon as its callback says nothing was
/// sent. Remembered longer, it would hold the control inert through a later
/// request that another control's press sent, when it should be disabled.
class EventRsvpControls extends StatefulWidget {
  const EventRsvpControls({
    required this.attendee,
    required this.enabled,
    required this.busy,
    required this.onAnswer,
    required this.onEditNote,
    super.key,
  });

  /// The viewer's own row on the roster: their answer, and their note.
  final EventAttendee attendee;

  /// Whether the controls may be pressed now: false while a read runs or a
  /// request is out.
  final bool enabled;

  /// Whether an action's request is out.
  final bool busy;

  /// Sends a new answer. Completes true when its write was sent, and false
  /// when nothing was: a dialog cancelled, or the write dropped.
  final Future<bool> Function(EventParticipationStatus status) onAnswer;

  /// Asks for the note and sends it with the current answer. Completes as
  /// [onAnswer] does.
  final Future<bool> Function() onEditNote;

  @override
  State<EventRsvpControls> createState() => _EventRsvpControlsState();
}

/// The answers with a chip, in the order they show.
const _answers = [
  EventParticipationStatus.attending,
  EventParticipationStatus.maybe,
  EventParticipationStatus.notAttending,
];

/// A press the controls remember: of [answer]'s chip, or of the note button
/// where [answer] is null.
final class _Press {
  _Press([this.answer]);

  final EventParticipationStatus? answer;

  /// Whether its write went out.
  bool sent = false;
}

class _EventRsvpControlsState extends State<EventRsvpControls> {
  _Press? _press;

  @override
  void didUpdateWidget(EventRsvpControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Built available after the press's write went out: the write and the
    // read its outcome started have ended, or ended before a frame showed
    // them, as a write that fails at once can.
    if ((_press?.sent ?? false) && widget.enabled && !widget.busy) {
      _press = null;
    }
  }

  void _answer(EventParticipationStatus status) {
    // The chosen answer pressed again changes nothing.
    if (status == widget.attendee.status) return;
    unawaited(_send(_Press(status), () => widget.onAnswer(status)));
  }

  void _editNote() => unawaited(_send(_Press(), widget.onEditNote));

  Future<void> _send(_Press press, Future<bool> Function() send) async {
    // One press at a time. A second inside the frame before the first shows
    // would take its place, and the control held would be the one whose
    // write is dropped.
    if (_press != null) return;
    // Nothing shows it until the controls are unavailable, which builds them.
    _press = press;
    var sent = false;
    try {
      sent = await send();
    } finally {
      press.sent = sent;
      if (!sent && mounted && identical(_press, press)) {
        setState(() => _press = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final attendee = widget.attendee;
    final status = attendee.status;
    final notes = attendee.notes;
    final offline = BgeConnectivityScope.offlineOf(context);
    final available = widget.enabled && !widget.busy;
    // While the controls are unavailable after a press, its control stays
    // inert and the others are disabled (#607). Offline every control is
    // disabled, the pressed one too: no press made it so (#49).
    final held = available || offline ? null : _press;
    bool inert(EventParticipationStatus? answer) =>
        held != null && held.answer == answer;
    bool pressable(EventParticipationStatus? answer) =>
        (available && !offline) || inert(answer);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spaceXs,
      children: [
        Semantics(
          container: true,
          explicitChildNodes: true,
          label: l10n.eventsRsvpQuestion,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: tokens.spaceXs,
            children: [
              // The group's name says it.
              ExcludeSemantics(
                child: Text(
                  l10n.eventsRsvpQuestion,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Wrap(
                spacing: tokens.spaceSm,
                runSpacing: tokens.spaceSm,
                children: [
                  for (final answer in _answers)
                    if (eventRsvpLabel(l10n, answer) case final label?)
                      _AnswerChip(
                        status: answer,
                        label: label,
                        selected: status == answer,
                        inert: inert(answer),
                        onPressed: pressable(answer)
                            ? () => _answer(answer)
                            : null,
                      ),
                ],
              ),
            ],
          ),
        ),
        if (status != EventParticipationStatus.unknown)
          _NoteButton(
            edits: notes != null && notes.isNotEmpty,
            inert: inert(null),
            onPressed: pressable(null) ? _editNote : null,
          ),
        // Only offline: online it would still take the Column's gap.
        if (offline) const BgeOnlineOnlyNote(),
      ],
    );
  }
}

/// One answer's chip, the same widgets whether it is enabled, inert or
/// disabled, so it keeps its focus and its node as it moves between them.
class _AnswerChip extends StatelessWidget {
  const _AnswerChip({
    required this.status,
    required this.label,
    required this.selected,
    required this.inert,
    required this.onPressed,
  });

  final EventParticipationStatus status;
  final String label;
  final bool selected;

  /// Whether it is held after its own press, ignoring presses.
  final bool inert;

  /// Null disables it.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // The write its press sent is under way. Once the answer lands it is
    // selected, and the check takes the spinner's place.
    final saving = inert && !selected;

    // Each chip carries the offline reason; the group is not wrapped, which
    // would merge its chips into one node, and shows it once below.
    return BgeOnlineOnly(
      showNote: false,
      child: BgeInertButton(
        inert: inert,
        // The chip itself shows the answer alone: a chip can't wrap a longer
        // label. Its spinner says the rest to a sighted user.
        label: saving
            ? EventsLocalizations.of(context).eventsRsvpAnswerInProgress(label)
            : label,
        selected: selected,
        onPressed: onPressed,
        builder: (context, focusNode, onPressed) => ChoiceChip(
          key: EventDetailScreen.rsvpAnswerKey(status),
          focusNode: focusNode,
          avatar: saving ? const _Spinner() : null,
          // A chip can't wrap its label, so one too long for the width at
          // large text scales down instead.
          label: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(label),
          ),
          selected: selected,
          // The chosen answer pressed again is ignored by the controls, not
          // here: a screen reader's tap reaches them past the chip.
          onSelected: onPressed == null ? null : (_) => onPressed(),
        ),
      ),
    );
  }
}

/// *Add a note*, or *Edit note* where there is one, and *Saving your note…*
/// while the note its press sent is out.
class _NoteButton extends StatelessWidget {
  const _NoteButton({
    required this.edits,
    required this.inert,
    required this.onPressed,
  });

  /// Whether there is a note to edit.
  final bool edits;

  /// Whether it is held after its own press, ignoring presses.
  final bool inert;

  /// Null disables it.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final label = switch ((inert, edits)) {
      (true, _) => l10n.eventsRsvpNoteInProgress,
      (false, true) => l10n.eventsRsvpEditNote,
      (false, false) => l10n.eventsRsvpAddNote,
    };

    return BgeOnlineOnly(
      showNote: false,
      child: BgeInertButton(
        inert: inert,
        label: label,
        onPressed: onPressed,
        builder: (context, focusNode, onPressed) => TextButton.icon(
          key: EventDetailScreen.rsvpNoteKey,
          focusNode: focusNode,
          onPressed: onPressed,
          icon: inert ? const _Spinner() : const Icon(Icons.edit_note),
          label: Text(label),
        ),
      ),
    );
  }
}

/// A held control's icon while the work its press started runs: scaled with
/// the label beside it, in the control's icon colour.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox.square(
      dimension: BgeTextScale.clampedOf(context)
          .scale(BgeTokens.of(context).spaceMd),
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: IconTheme.of(context).color,
      ),
    ),
  );
}
