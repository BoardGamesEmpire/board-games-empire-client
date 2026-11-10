import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Asks for the note that goes with the viewer's answer to an event's
/// invitation (#508), with [note], the one they left, in the field.
///
/// Null when cancelled; otherwise the note, trimmed, or '' for none, which
/// clears it. The server takes a note of any length, so the field checks
/// none. Saving a note takes nothing away, so Save is drawn as an ordinary
/// button, not a destructive one.
Future<String?> showRsvpNoteDialog(BuildContext context, {String? note}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _RsvpNoteDialog(note: note),
    );

class _RsvpNoteDialog extends StatefulWidget {
  const _RsvpNoteDialog({this.note});

  final String? note;

  @override
  State<_RsvpNoteDialog> createState() => _RsvpNoteDialogState();
}

class _RsvpNoteDialogState extends State<_RsvpNoteDialog> {
  late final FormGroup _form;

  @override
  void initState() {
    super.initState();
    _form = FormGroup({_note: FormControl<String>(value: widget.note)});
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _save() =>
      Navigator.of(context)
          .pop(trimmedOrNull(_form.control(_note).value) ?? '');

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return ReactiveForm(
      formGroup: _form,
      child: AlertDialog(
        // At 2.0 text the body and a long note can outgrow a phone's height.
        scrollable: true,
        title: Text(l10n.eventsRsvpNoteTitle),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.eventsRsvpNoteBody),
            const BgeGap.md(),
            BgeTextField(
              key: EventDetailScreen.rsvpNoteFieldKey,
              formControlName: _note,
              label: l10n.eventsRsvpNoteLabel,
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
            child: Text(l10n.eventsRsvpNoteKeep),
          ),
          TextButton(
            key: EventDetailScreen.rsvpNoteSaveKey,
            onPressed: _save,
            child: Text(l10n.eventsRsvpNoteSave),
          ),
        ],
      ),
    );
  }
}

const _note = 'note';
