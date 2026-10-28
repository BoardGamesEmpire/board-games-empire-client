import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../create/event_create_controls.dart';
import 'event_labels.dart';
import 'event_when_field.dart';

// The dialogs an event's dates are changed through (#506): add and edit,
// which share one form, and confirm, decline, cancel and remove, which ask
// before a change that can't be taken back. Each answers what the user
// chose, and sends nothing: the detail screen does.
//
// Every one is scrollable, as the delete dialog is: at 2.0 text a long name
// and the body can outgrow a phone's height. Its buttons stay below the
// scroll, on screen.

/// Keys on the date dialogs' fields and buttons (#506).
abstract final class EventDateDialogKeys {
  static const Key label = Key('event_date_dialog.label');
  static const Key start = Key('event_date_dialog.start');
  static const Key end = Key('event_date_dialog.end');

  /// The end's clear button, there while the end is set.
  static const Key clearEnd = Key('event_date_dialog.clear_end');
  static const Key location = Key('event_date_dialog.location');
  static const Key reason = Key('event_date_dialog.reason');

  /// The button that does what the dialog is for: Add, Save, Confirm,
  /// Decline, Cancel date or Remove.
  static const Key submit = Key('event_date_dialog.submit');

  /// The button that closes the dialog and changes nothing: Discard or Keep
  /// date.
  static const Key dismiss = Key('event_date_dialog.dismiss');
}

/// Asks for a date to add: its label, when it starts and ends, and its
/// place. Answers the draft, or null when discarded.
///
/// The add is sent as given, so the draft is trimmed here: a label or place
/// that is blank once trimmed is none. Times go out in UTC, as the create
/// form's do.
Future<EventOccurrenceDraft?> showAddDateDialog(
  BuildContext context, {
  required DateTime Function() now,
}) => showDialog<EventOccurrenceDraft>(
  context: context,
  builder: (_) => _DateDialog(now: now),
);

/// Asks what to change of [occurrence]. Answers only what changed, or null
/// when discarded.
///
/// Save waits for a change. Text is compared trimmed, as it is sent, so a
/// label changed only by whitespace is no change, and a label or place
/// emptied is cleared. Times are compared as moments: the form holds them
/// in local time and the date in UTC. A confirmed date says first that
/// nobody is told of the change.
Future<OccurrenceUpdate?> showEditDateDialog(
  BuildContext context,
  EventOccurrence occurrence, {
  required DateTime Function() now,
}) => showDialog<OccurrenceUpdate>(
  context: context,
  builder: (_) => _DateDialog(now: now, editing: occurrence),
);

/// Asks whether to confirm [dateName]. Confirming is for good: the date can
/// be cancelled after, but not proposed again.
Future<bool> showConfirmDateDialog(BuildContext context, String dateName) {
  final l10n = EventsLocalizations.of(context);
  return _ask(
    context,
    title: l10n.eventsDateConfirmTitle(dateName),
    body: l10n.eventsDateConfirmBody,
    action: l10n.eventsDateConfirm,
  );
}

/// Asks whether to decline [dateName], which is for good.
Future<bool> showDeclineDateDialog(BuildContext context, String dateName) {
  final l10n = EventsLocalizations.of(context);
  return _ask(
    context,
    title: l10n.eventsDateDeclineTitle(dateName),
    body: l10n.eventsDateDeclineBody,
    action: l10n.eventsDateDecline,
    destructive: true,
  );
}

/// Asks whether to cancel [dateName], with an optional reason. Where
/// [removing], it asks whether to remove the date, which for a Confirmed
/// date is a cancel and then a remove (#446), and the reason goes with that
/// cancel.
///
/// Null when kept; otherwise the reason, trimmed, or '' for none. A reason
/// longer than [EventRemoteDataSource.maxCancelReasonLength] once trimmed is
/// refused in the field, since the server's 400 for it is permanent.
Future<String?> showCancelDateDialog(
  BuildContext context,
  String dateName, {
  required bool removing,
}) => showDialog<String>(
  context: context,
  builder: (_) => _CancelDialog(dateName: dateName, removing: removing),
);

/// Asks whether to remove [dateName], which can't be undone. For a date
/// that isn't Confirmed: a Confirmed one asks through
/// [showCancelDateDialog].
Future<bool> showRemoveDateDialog(BuildContext context, String dateName) {
  final l10n = EventsLocalizations.of(context);
  return _ask(
    context,
    title: l10n.eventsDateRemoveTitle(dateName),
    body: l10n.eventsDateRemoveBody,
    action: l10n.eventsDateRemove,
    destructive: true,
  );
}

/// A dialog that asks whether to go ahead, and answers whether the user
/// did. Keep date, not Cancel: cancelling a date is one of the things these
/// dialogs ask about. A [destructive] action is drawn in the error colour,
/// as Delete's is.
Future<bool> _ask(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final l10n = EventsLocalizations.of(dialogContext);
      return AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: EventDateDialogKeys.dismiss,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.eventsDateKeep),
          ),
          TextButton(
            key: EventDateDialogKeys.submit,
            style: destructive ? _destructive(dialogContext) : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// An action that can't be undone, in the error colour.
ButtonStyle _destructive(BuildContext context) =>
    TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error);

// The add and edit form's controls.
const _label = 'label', _start = 'start', _end = 'end', _location = 'location';

/// The add and edit dialog: one form, empty to add, holding [editing]'s
/// fields to edit it. It pops with the draft or the update the form shows.
///
/// An added date needs a start, and no end may come before its start. A
/// submit refused for either shows the error and focuses its field, as the
/// create form's does.
class _DateDialog extends StatefulWidget {
  const _DateDialog({required this.now, this.editing});

  final DateTime Function() now;

  /// The date being edited, or null to add one.
  final EventOccurrence? editing;

  @override
  State<_DateDialog> createState() => _DateDialogState();
}

class _DateDialogState extends State<_DateDialog> {
  late final FormGroup _form = _buildForm(widget.editing);

  FormControl<DateTime> get _startControl =>
      _form.control(_start) as FormControl<DateTime>;

  FormControl<DateTime> get _endControl =>
      _form.control(_end) as FormControl<DateTime>;

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final editing = widget.editing;
    Navigator.of(context)
        .pop(editing == null ? _draftOf(_form) : _updateOf(_form, editing));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final editing = widget.editing;
    final start = _startControl;
    final end = _endControl;

    return ReactiveForm(
      formGroup: _form,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          editing == null
              ? l10n.eventsDateAddTitle
              : l10n.eventsDateEditTitle(
                  eventDateName(context, editing, now: widget.now()),
                ),
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (editing?.status == OccurrenceStatus.confirmed) ...[
              Text(
                l10n.eventsDateEditConfirmedNote,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const BgeGap.md(),
            ],
            BgeTextField(
              key: EventDateDialogKeys.label,
              formControlName: _label,
              label: l10n.eventCreateDayLabel,
            ),
            const BgeGap.md(),
            EventWhenField(
              key: EventDateDialogKeys.start,
              control: start,
              label: l10n.eventCreateStart,
              validationMessages: {
                ValidationMessage.required: (_) => l10n.eventCreateDateRequired,
              },
              readOnly: false,
              now: widget.now,
            ),
            const BgeGap.md(),
            ReactiveValueListenableBuilder<DateTime>(
              formControl: end,
              // Always a row, so the field keeps its place in the tree when
              // the clear button comes and goes, as on the create form.
              builder: (context, control, _) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: EventWhenField(
                      key: EventDateDialogKeys.end,
                      control: end,
                      opensOn: start,
                      label: l10n.eventCreateEnd,
                      validationMessages: {
                        EventCreateErrors.endBeforeStart: (_) =>
                            l10n.eventCreateEndBeforeStart,
                      },
                      readOnly: false,
                      now: widget.now,
                    ),
                  ),
                  if (control.value != null)
                    IconButton(
                      key: EventDateDialogKeys.clearEnd,
                      tooltip: l10n.eventCreateClearEnd,
                      icon: const Icon(Icons.clear),
                      onPressed: () => end.value = null,
                    ),
                ],
              ),
            ),
            const BgeGap.md(),
            BgeTextField(
              key: EventDateDialogKeys.location,
              formControlName: _location,
              label: l10n.eventCreateLocation,
              textInputAction: TextInputAction.done,
            ),
          ],
        ),
        actions: [
          TextButton(
            key: EventDateDialogKeys.dismiss,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.eventsDateDiscard),
          ),
          if (editing == null)
            TextButton(
              key: EventDateDialogKeys.submit,
              onPressed: _submit,
              child: Text(l10n.eventsDateAddConfirm),
            )
          else
            // Rebuilt with the form, which says when a value changes.
            ReactiveFormConsumer(
              builder: (context, form, _) => TextButton(
                key: EventDateDialogKeys.submit,
                onPressed: _updateOf(form, editing) == null ? null : _submit,
                child: Text(l10n.eventsDateSave),
              ),
            ),
        ],
      ),
    );
  }
}

/// The add and edit form, holding [editing]'s fields where there is one.
/// Times are held in local time, as the pickers give them.
FormGroup _buildForm(EventOccurrence? editing) => FormGroup(
  {
    _label: FormControl<String>(value: editing?.label),
    // Required to add. A poll's date can have none, which the server
    // takes, and renaming one mustn't make the user pick a time. Once set,
    // a start can't be cleared.
    _start: FormControl<DateTime>(
      value: editing?.startDate?.toLocal(),
      validators: [if (editing == null) Validators.required],
    ),
    _end: FormControl<DateTime>(value: editing?.endDate?.toLocal()),
    _location: FormControl<String>(value: editing?.location),
  },
  validators: [Validators.delegate(_checkEnd)],
);

/// The end's check, as the create form's dates check runs it on each row.
Map<String, dynamic>? _checkEnd(AbstractControl<dynamic> control) {
  final form = control as FormGroup;
  checkEndBeforeStart(form.control(_start), form.control(_end));
  return null;
}

/// The date the add form shows, trimmed, with its times in UTC.
EventOccurrenceDraft _draftOf(FormGroup form) => EventOccurrenceDraft(
  label: trimmedOrNull(form.control(_label).value),
  startDate: (form.control(_start).value as DateTime?)?.toUtc(),
  endDate: (form.control(_end).value as DateTime?)?.toUtc(),
  location: trimmedOrNull(form.control(_location).value),
);

/// What the edit form changes of [occurrence], or null where it changes
/// nothing. Never one [OccurrenceUpdate] would refuse: a value and its own
/// clear are never both set, and text is trimmed, so it is never blank.
///
/// The start can't be cleared, so a form with none changes nothing there.
OccurrenceUpdate? _updateOf(FormGroup form, EventOccurrence occurrence) {
  final label = trimmedOrNull(form.control(_label).value);
  final start = form.control(_start).value as DateTime?;
  final end = form.control(_end).value as DateTime?;
  final location = trimmedOrNull(form.control(_location).value);

  final labelChanged = label != trimmedOrNull(occurrence.label);
  final newStart = start == null || _sameMoment(start, occurrence.startDate)
      ? null
      : start.toUtc();
  final endChanged = !_sameMoment(end, occurrence.endDate);
  final locationChanged = location != trimmedOrNull(occurrence.location);
  if (!labelChanged && newStart == null && !endChanged && !locationChanged) {
    return null;
  }

  return OccurrenceUpdate(
    label: labelChanged ? label : null,
    clearLabel: labelChanged && label == null,
    startDate: newStart,
    endDate: endChanged ? end?.toUtc() : null,
    clearEndDate: endChanged && end == null,
    location: locationChanged ? location : null,
    clearLocation: locationChanged && location == null,
  );
}

/// Whether [a] and [b] are the same moment, or both none. Not `==`, which
/// is false for one moment held in UTC and in local time.
bool _sameMoment(DateTime? a, DateTime? b) =>
    a == null ? b == null : b != null && a.isAtSameMomentAs(b);

/// The cancel dialog, for [showCancelDateDialog].
class _CancelDialog extends StatefulWidget {
  const _CancelDialog({required this.dateName, required this.removing});

  final String dateName;
  final bool removing;

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final FormGroup _form = FormGroup({
    _reason: FormControl<String>(
      validators: [Validators.delegate(_checkReason)],
    ),
  });

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    Navigator.of(context)
        .pop(trimmedOrNull(_form.control(_reason).value) ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final removing = widget.removing;

    return ReactiveForm(
      formGroup: _form,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          removing
              ? l10n.eventsDateRemoveTitle(widget.dateName)
              : l10n.eventsDateCancelTitle(widget.dateName),
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              removing
                  ? l10n.eventsDateCancelRemoveBody
                  : l10n.eventsDateCancelBody,
            ),
            const BgeGap.md(),
            BgeTextField(
              key: EventDateDialogKeys.reason,
              formControlName: _reason,
              label: l10n.eventsDateReason,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: 4,
              validationMessages: {
                _reasonTooLong: (_) => l10n.eventsDateReasonTooLong(
                  EventRemoteDataSource.maxCancelReasonLength,
                ),
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            key: EventDateDialogKeys.dismiss,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.eventsDateKeep),
          ),
          TextButton(
            key: EventDateDialogKeys.submit,
            style: _destructive(context),
            onPressed: _submit,
            child: Text(
              removing ? l10n.eventsDateRemove : l10n.eventsDateCancel,
            ),
          ),
        ],
      ),
    );
  }
}

const _reason = 'reason';

/// On a reason longer than the server takes.
const _reasonTooLong = 'reasonTooLong';

/// [_reasonTooLong] on a reason longer than
/// [EventRemoteDataSource.maxCancelReasonLength] once trimmed, as the remote
/// counts it.
Map<String, dynamic>? _checkReason(AbstractControl<dynamic> control) {
  final reason = (control.value as String?)?.trim() ?? '';
  return reason.length > EventRemoteDataSource.maxCancelReasonLength
      ? const {_reasonTooLong: true}
      : null;
}
