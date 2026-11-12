import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What a vote of [type] is called: on the vote control's choices, and in
/// who voted.
String voteTypeLabel(EventsLocalizations l10n, VoteType type) => switch (type) {
  VoteType.forGame => l10n.eventsVoteFor,
  VoteType.against => l10n.eventsVoteAgainst,
  VoteType.interested => l10n.eventsVoteInterested,
  VoteType.unknown => l10n.eventsVoteUnknown,
};

/// The viewer's vote on an open nomination (#517): For, Against and
/// Interested as one single-choice [SegmentedButton], their vote chosen and
/// marked with a check, and *Add a note* or *Edit note* under it for the note
/// that goes with it. Above it, where [hint] says so, a line on when their
/// vote will count.
///
/// Pressing a choice sends it. The control never clears: a vote can be
/// changed, never taken back (backend#1212), so the chosen one pressed again
/// sends nothing, and nothing is chosen only before the viewer has voted. A
/// note goes out with the vote as it stands, so the note button waits for a
/// vote, and for one this client can read.
///
/// Each choice is named to a screen reader with its game, since every open
/// nomination has the same three. Each is a direct write, so offline every
/// control is disabled, carrying the reason as its hint, and one note under
/// them says why (#49).
///
/// ## Held through a write
///
/// One write goes out at a time, as the RSVP's controls have it (#508). The
/// control remembers a press, and ignores any other until it forgets it. While
/// the control is unavailable after it, through its write and the read of the
/// nomination after it ([busy]), the pressed choice or note button stays
/// enabled and ignores presses, so it keeps a keyboard user's focus (#607),
/// and the others are disabled. The pressed choice shows a spinner, and its
/// name says its vote is being saved; the note button says its note is. A
/// choice's node still offers its tap while held, since a segment builds its
/// own node, but the tap sends nothing. The press is forgotten the first time
/// the control is built available after its write went out, and as soon as
/// its callback says nothing was sent.
class NominationVoteControl extends StatefulWidget {
  const NominationVoteControl({
    required this.nomination,
    required this.vote,
    required this.hint,
    required this.enabled,
    required this.busy,
    required this.onVote,
    required this.onEditNote,
    super.key,
  });

  /// The open nomination voted on.
  final EventNomination nomination;

  /// The viewer's vote on it, or null before they have voted.
  final EventNominationVote? vote;

  /// When the viewer's vote will count, where it won't now, or null where
  /// nothing needs saying ([voteHintFor]).
  final VoteHint? hint;

  /// Whether the control may be pressed now, connection and writes aside:
  /// false while a detail read runs, or the screen's own request is out.
  final bool enabled;

  /// Whether a nominations write is out, this control's or another's.
  final bool busy;

  /// Sends a vote of the type given. Completes true when its write was
  /// sent, and false when nothing was.
  final Future<bool> Function(VoteType type) onVote;

  /// Asks for the note and sends it with the vote as it stands. Completes as
  /// [onVote] does: false for a dialog cancelled or a note unchanged too.
  final Future<bool> Function() onEditNote;

  @override
  State<NominationVoteControl> createState() => _NominationVoteControlState();
}

/// A press the control remembers: of [vote]'s choice, or of the note button
/// where [vote] is null.
final class _Press {
  _Press([this.vote]);

  final VoteType? vote;

  /// Whether its write went out.
  bool sent = false;
}

class _NominationVoteControlState extends State<NominationVoteControl> {
  _Press? _press;

  @override
  void didUpdateWidget(NominationVoteControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Built available after the press's write went out: the write and the
    // read after it have ended, or ended before a frame showed them, as a
    // write that fails at once can.
    if ((_press?.sent ?? false) && widget.enabled && !widget.busy) {
      _press = null;
    }
  }

  void _choose(Set<VoteType> chosen) {
    // Pressed again, the chosen vote would clear, and a vote can't be taken
    // back: nothing changes.
    if (chosen.isEmpty) return;
    final type = chosen.single;
    if (type == widget.vote?.voteType) return;
    unawaited(_send(_Press(type), () => widget.onVote(type)));
  }

  void _editNote() => unawaited(_send(_Press(), widget.onEditNote));

  Future<void> _send(_Press press, Future<bool> Function() send) async {
    // One press at a time. A second inside the frame before the first shows
    // would take its place, and the control held would be the one whose
    // write is dropped.
    if (_press != null) return;
    // Nothing shows it until the control is unavailable, which builds it.
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
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final nomination = widget.nomination;
    final id = nomination.id;
    final title = nomination.title;
    // A vote this client can't read is none it can show, nor send a note
    // with: it has no name to send.
    final voted = switch (widget.vote?.voteType) {
      VoteType.unknown || null => null,
      final type => type,
    };
    final note = widget.vote?.comment;
    final offline = BgeConnectivityScope.offlineOf(context);
    final available = widget.enabled && !widget.busy;
    // While the control is unavailable after a press, what was pressed stays
    // inert and the rest is disabled (#607). Offline everything is disabled,
    // the pressed one too: no press made it so (#49).
    final held = available || offline ? null : _press;
    bool inert(VoteType? vote) => held != null && held.vote == vote;
    bool pressable(VoteType? vote) => (available && !offline) || inert(vote);
    final hint = switch (widget.hint) {
      VoteHint.countsWhenAttending => l10n.eventsVoteHintAttending,
      VoteHint.countsWhenOffering => l10n.eventsVoteHintOffering,
      null => null,
    };
    final choices = [
      (VoteType.forGame, l10n.eventsVoteFor, l10n.eventsVoteForNamed(title)),
      (
        VoteType.against,
        l10n.eventsVoteAgainst,
        l10n.eventsVoteAgainstNamed(title),
      ),
      (
        VoteType.interested,
        l10n.eventsVoteInterested,
        l10n.eventsVoteInterestedNamed(title),
      ),
    ];

    // The note button sits a control's gap under the choices; the hint, a
    // line about them, sits as close as helper text does.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spaceSm,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: tokens.spaceXs,
          children: [
            if (hint != null)
              Text(
                hint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            SegmentedButton<VoteType>(
              // Nothing is chosen before the viewer votes; after, the chosen
              // vote pressed again is ignored in [_choose], so it never clears.
              emptySelectionAllowed: true,
              selected: {?voted},
              onSelectionChanged: choices.any((choice) => pressable(choice.$1))
                  ? _choose
                  : null,
              // The chosen vote's check is drawn in its label instead, so that
              // it scales down with the word rather than leave the word less
              // room, and the segments' padding is tighter than a button's, for
              // the same room.
              showSelectedIcon: false,
              style: ButtonStyle(
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: tokens.spaceSm),
                ),
              ),
              segments: [
                for (final (type, label, named) in choices)
                  ButtonSegment(
                    value: type,
                    enabled: pressable(type),
                    // Each choice carries the offline reason; the group is not
                    // wrapped, which would merge its choices into one node, and
                    // shows it once below.
                    label: BgeOnlineOnly(
                      showNote: false,
                      // Three share the row's width, so a label too long for
                      // its third at large text scales down, its mark with it,
                      // and never wraps or clips. One line: a segment's height
                      // comes from its label's, and a label that could wrap
                      // would ask for the height of every line it might take.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: tokens.spaceXs,
                          children: [
                            // The chosen vote is marked by more than its
                            // colour. The vote its press sent is under way:
                            // once it lands it is chosen, and the check takes
                            // the spinner's place.
                            if (voted == type)
                              const Icon(Icons.check)
                            else if (inert(type))
                              const _SegmentSpinner(),
                            Text(
                              key: EventDetailScreen.nominationVoteKey(
                                id,
                                type,
                              ),
                              label,
                              maxLines: 1,
                              softWrap: false,
                              semanticsLabel: inert(type)
                                  ? l10n.eventsVoteInProgress(named)
                                  : named,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        _NoteButton(
          nomination: nomination,
          edits: note != null && note.isNotEmpty,
          inert: inert(null),
          // A note goes out with the vote as it stands, so it waits for one.
          onPressed: voted != null && pressable(null) ? _editNote : null,
        ),
        // Only offline: online it would still take the Column's gap.
        if (offline) const BgeOnlineOnlyNote(),
      ],
    );
  }
}

/// *Add a note*, or *Edit note* where there is one, and *Saving your note…*
/// while the note its press sent is out. Named for its game to a screen
/// reader.
class _NoteButton extends StatelessWidget {
  const _NoteButton({
    required this.nomination,
    required this.edits,
    required this.inert,
    required this.onPressed,
  });

  final EventNomination nomination;

  /// Whether there is a note to edit.
  final bool edits;

  /// Whether it is held after its own press, ignoring presses.
  final bool inert;

  /// Null disables it.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final title = nomination.title;
    final (label, named) = switch ((inert, edits)) {
      (true, _) => (
        l10n.eventsVoteNoteInProgress,
        l10n.eventsVoteNoteInProgress,
      ),
      (false, true) => (
        l10n.eventsVoteEditNote,
        l10n.eventsVoteEditNoteNamed(title),
      ),
      (false, false) => (
        l10n.eventsVoteAddNote,
        l10n.eventsVoteAddNoteNamed(title),
      ),
    };

    return BgeOnlineOnly(
      showNote: false,
      child: BgeInertButton(
        inert: inert,
        label: named,
        onPressed: onPressed,
        builder: (context, focusNode, onPressed) => TextButton.icon(
          key: EventDetailScreen.nominationNoteKey(nomination.id),
          focusNode: focusNode,
          onPressed: onPressed,
          icon: inert ? const _Spinner() : const Icon(Icons.edit_note),
          label: Text(label),
        ),
      ),
    );
  }
}

/// A held choice's mark while the vote its press sent is out: the size of
/// the check that takes its place, in the segment's icon colour.
class _SegmentSpinner extends StatelessWidget {
  const _SegmentSpinner();

  @override
  Widget build(BuildContext context) {
    final icons = IconTheme.of(context);

    return SizedBox.square(
      dimension: icons.size,
      child: CircularProgressIndicator(strokeWidth: 2, color: icons.color),
    );
  }
}

/// A held control's icon while the work its press started runs: scaled with
/// the label beside it, in the control's icon colour.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: BgeTextScale.clampedOf(
      context,
    ).scale(BgeTokens.of(context).spaceMd),
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: IconTheme.of(context).color,
    ),
  );
}

/// Asks for the note that goes with the viewer's vote on the game titled
/// [title] (#517), with [note], the one they left, in the field.
///
/// Null when cancelled; otherwise the note, trimmed, or '' for none, which
/// clears it. The field takes a note of any length, as the server does: a
/// cap here would cut short a longer note another client left, the first
/// time it was edited. Saving a note takes nothing away, so Save is drawn as
/// an ordinary button, not a destructive one.
Future<String?> showNominationNoteDialog(
  BuildContext context, {
  required String title,
  String? note,
}) => showDialog<String>(
  context: context,
  builder: (_) => _NoteDialog(title: title, note: note),
);

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.title, this.note});

  final String title;
  final String? note;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final FormGroup _form = FormGroup({
    _noteControl: FormControl<String>(value: widget.note),
  });

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(
    context,
  ).pop((_form.control(_noteControl).value as String? ?? '').trim());

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final title = l10n.eventsVoteNoteTitle(widget.title);

    return ReactiveForm(
      formGroup: _form,
      child: AlertDialog(
        // At 2.0 text the body and a long note can outgrow a phone's height.
        scrollable: true,
        // Without it the dialog has no name on iOS and macOS (#762).
        semanticLabel: title,
        title: Text(title),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.eventsVoteNoteBody),
            const BgeGap.md(),
            // No check that could fail: any note goes, and an empty one
            // clears it.
            BgeTextField(
              key: EventDetailScreen.nominationNoteFieldKey,
              formControlName: _noteControl,
              label: l10n.eventsVoteNoteLabel,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: 4,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.eventsVoteNoteKeep),
          ),
          TextButton(
            key: EventDetailScreen.nominationNoteSaveKey,
            onPressed: _save,
            child: Text(l10n.eventsVoteNoteSave),
          ),
        ],
      ),
    );
  }
}

const _noteControl = 'note';
