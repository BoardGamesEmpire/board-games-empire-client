import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/widgets/destructive_button_style.dart';
import 'package:flutter/material.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Asks whether to cancel, with an optional reason: one dialog for a date's
/// cancel and an event's (#502), so the field and its check are the same in
/// both. The caller gives the copy; the field's label and its too-long
/// message are the dialog's own.
///
/// Null when kept; otherwise the reason, trimmed, or '' for none. A reason
/// longer than [EventRemoteDataSource.maxCancelReasonLength] code points
/// once trimmed is refused in the field, since the server's 400 for it is
/// permanent. The confirm button is drawn as destructive.
Future<String?> showCancelReasonDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String keepLabel,
  required String confirmLabel,
  Key? reasonKey,
  Key? keepKey,
  Key? confirmKey,
}) => showDialog<String>(
  context: context,
  builder: (_) => _CancelReasonDialog(
    title: title,
    body: body,
    keepLabel: keepLabel,
    confirmLabel: confirmLabel,
    reasonKey: reasonKey,
    keepKey: keepKey,
    confirmKey: confirmKey,
  ),
);

class _CancelReasonDialog extends StatefulWidget {
  const _CancelReasonDialog({
    required this.title,
    required this.body,
    required this.keepLabel,
    required this.confirmLabel,
    this.reasonKey,
    this.keepKey,
    this.confirmKey,
  });

  final String title;
  final String body;
  final String keepLabel;
  final String confirmLabel;
  final Key? reasonKey;
  final Key? keepKey;
  final Key? confirmKey;

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
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

    return ReactiveForm(
      formGroup: _form,
      child: AlertDialog(
        scrollable: true,
        title: Text(widget.title),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.body),
            const BgeGap.md(),
            BgeTextField(
              key: widget.reasonKey,
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
            key: widget.keepKey,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.keepLabel),
          ),
          TextButton(
            key: widget.confirmKey,
            style: destructiveButtonStyle(context),
            onPressed: _submit,
            child: Text(widget.confirmLabel),
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
  return reason.runes.length > EventRemoteDataSource.maxCancelReasonLength
      ? const {_reasonTooLong: true}
      : null;
}
