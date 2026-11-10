import 'dart:async';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The add and edit form for a DataGateway (#41): a name, the address and
/// port the server dials, and an optional description.
///
/// No credentials field. Only the "None" auth type connects today, so the
/// form says that instead of asking for credentials nothing would use (#41).
/// An edit of a row created elsewhere with another auth type leaves it alone,
/// and the note says so instead.
///
/// Owns its [FormGroup], like `CreateHouseholdForm`, and hands [onSubmit]
/// trimmed, validated values. For an edit, [initial] fills the fields; which
/// of them changed is the caller's question, not the form's.
///
/// When [maySave] is false the fields are read-only and the submit goes. Once
/// [accessKnown] says the caller's access has answered, the reason takes its
/// place: the user's role may not change DataGateways. While it has not,
/// nothing does, because nothing about the role is known yet (#456). A
/// submit that goes with keyboard focus hands it to the last field, the stop
/// just before it, which stays as a read-only field.
class DataGatewayForm extends StatefulWidget {
  const DataGatewayForm({
    required this.onSubmit,
    required this.submitLabel,
    required this.maySave,
    required this.accessKnown,
    this.initial,
    this.submitting = false,
    this.failure,
    this.onEdited,
    super.key,
  });

  static const Key nameFieldKey = Key('data_gateway_form.name');
  static const Key addressFieldKey = Key('data_gateway_form.address');
  static const Key portFieldKey = Key('data_gateway_form.port');
  static const Key descriptionFieldKey = Key('data_gateway_form.description');
  static const Key submitKey = Key('data_gateway_form.submit');
  static const Key refusedKey = Key('data_gateway_form.refused');

  final void Function(DataGatewayInput input) onSubmit;
  final String submitLabel;
  final DataGateway? initial;
  final bool submitting;
  final bool maySave;

  /// Whether the caller's access has answered, so that a [maySave] of false
  /// is a refusal to say, not an answer still to come.
  final bool accessKnown;

  final BgeFormFailure? failure;

  /// Called on every edit, so the caller can retire a failure that describes
  /// the values being replaced (#191).
  final VoidCallback? onEdited;

  @override
  State<DataGatewayForm> createState() => _DataGatewayFormState();
}

class _DataGatewayFormState extends State<DataGatewayForm> {
  static const String _portError = 'port';

  late final FormGroup _form = FormGroup({
    'name': FormControl<String>(
      value: widget.initial?.name,
      validators: [Validators.delegate(_requiredTrimmed)],
    ),
    'address': FormControl<String>(
      value: widget.initial?.connectionUrl,
      validators: [Validators.delegate(_requiredTrimmed)],
    ),
    'port': FormControl<String>(
      value: widget.initial?.connectionPort.toString(),
      validators: [Validators.delegate(_validPort)],
    ),
    'description': FormControl<String>(value: widget.initial?.description),
  });

  StreamSubscription<Object?>? _editSubscription;

  /// The node of the [Focus] around the submit and the failure above it,
  /// which go when [DataGatewayForm.maySave] falls. `BgeSubmitButton` takes
  /// no focus node of its own, so this is the handle on it. It can't take
  /// focus itself: focus goes to the button inside.
  final FocusNode _actions = FocusNode(
    debugLabel: 'data gateway form actions',
    canRequestFocus: false,
  );

  /// Required after trimming, as `CreateHouseholdForm` does it, so a value of
  /// spaces fails here rather than on the server.
  static Map<String, dynamic>? _requiredTrimmed(
    AbstractControl<dynamic> control,
  ) {
    final value = control.value;
    final trimmed = value is String ? value.trim() : '';
    return trimmed.isEmpty
        ? <String, dynamic>{ValidationMessage.required: true}
        : null;
  }

  /// Digits only. `int.tryParse` alone also takes a sign and a `0x` prefix,
  /// so "0x50" would pass and save port 80.
  static final RegExp _digits = RegExp(r'^[0-9]+$');

  /// A whole number from 1 to 65535, the backend's own bounds.
  static Map<String, dynamic>? _validPort(AbstractControl<dynamic> control) {
    final value = control.value;
    final text = value is String ? value.trim() : '';
    final port = _digits.hasMatch(text) ? int.tryParse(text) : null;
    return port == null || port < 1 || port > 65535
        ? <String, dynamic>{_portError: true}
        : null;
  }

  @override
  void initState() {
    super.initState();
    _editSubscription = _form.valueChanges.listen((_) {
      if (mounted) widget.onEdited?.call();
    });
  }

  @override
  void didUpdateWidget(DataGatewayForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.maySave && !widget.maySave && _actions.hasFocus) {
      _handOnFocus();
    }
  }

  /// Hands keyboard focus from the submit, which this build takes away, to
  /// the last field (#456).
  ///
  /// The caller's access can fall at any time, whenever the session asks
  /// again. Left to go with the submit, focus would fall back on whatever had
  /// it before, or on the page with nothing to show for it. The last field is
  /// the stop just before the submit, so the user keeps their place, and the
  /// reason that replaces the submit is the next thing below it.
  ///
  /// Runs while building the frame that takes the submit away, while it
  /// still has focus.
  void _handOnFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _form.control('description').focus();
    });
  }

  @override
  void dispose() {
    unawaited(_editSubscription?.cancel());
    _form.dispose();
    _actions.dispose();
    super.dispose();
  }

  String _text(String name) =>
      (_form.control(name).value as String?)?.trim() ?? '';

  void _submit() {
    // Saving is a direct write (#49). Returning before the validity check
    // keeps an offline press from marking the form touched.
    if (widget.submitting ||
        !widget.maySave ||
        BgeConnectivityScope.offlineOf(context)) {
      return;
    }
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final description = _text('description');
    widget.onSubmit(
      DataGatewayInput(
        name: _text('name'),
        connectionUrl: _text('address'),
        connectionPort: int.parse(_text('port')),
        description: description.isEmpty ? null : description,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final readOnly = widget.submitting || !widget.maySave;

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeTextField(
            key: DataGatewayForm.nameFieldKey,
            formControlName: 'name',
            label: l10n.dataGatewayFormNameLabel,
            readOnly: readOnly,
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.dataGatewayFormNameRequired,
            },
          ),
          const BgeGap.md(),
          BgeTextField(
            key: DataGatewayForm.addressFieldKey,
            formControlName: 'address',
            label: l10n.dataGatewayFormAddressLabel,
            helper: l10n.dataGatewayFormAddressHelper,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.dataGatewayFormAddressRequired,
            },
          ),
          const BgeGap.md(),
          BgeTextField(
            key: DataGatewayForm.portFieldKey,
            formControlName: 'port',
            label: l10n.dataGatewayFormPortLabel,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {
              _portError: (_) => l10n.dataGatewayFormPortInvalid,
            },
          ),
          const BgeGap.md(),
          BgeTextField(
            key: DataGatewayForm.descriptionFieldKey,
            formControlName: 'description',
            label: l10n.dataGatewayFormDescriptionLabel,
            readOnly: readOnly,
            textInputAction: TextInputAction.done,
            minLines: 1,
            maxLines: 3,
            onSubmitted: _submit,
          ),
          const BgeGap.md(),
          BgeInlineBanner(
            // A row created elsewhere with another auth type keeps it: an edit
            // sends only the fields that changed, and the auth type is not
            // one of them. So the note must not claim it has no credentials.
            message: switch (widget.initial?.authType ??
                DataGatewayAuthType.none) {
              DataGatewayAuthType.none => l10n.dataGatewayFormNoCredentials,
              DataGatewayAuthType.bearer ||
              DataGatewayAuthType.mutualTls ||
              DataGatewayAuthType.unknown =>
                l10n.dataGatewayFormKeepsCredentials,
            },
            // Standing context, not news: nothing to announce on arrival.
            announce: false,
            reveal: false,
          ),
          const BgeGap.lg(),
          if (widget.maySave)
            Focus(
              focusNode: _actions,
              child: BgeFormActions(
                failure: widget.failure,
                action: BgeOnlineOnly(
                  child: BgeSubmitButton(
                    key: DataGatewayForm.submitKey,
                    label: widget.submitLabel,
                    progressLabel: l10n.dataGatewayFormInProgress,
                    submitting: widget.submitting,
                    onPressed: BgeConnectivityScope.offlineOf(context)
                        ? null
                        : _submit,
                  ),
                ),
              ),
            )
          else if (widget.accessKnown)
            BgeInlineBanner(
              key: DataGatewayForm.refusedKey,
              message: l10n.dataGatewayChangeRefused,
              // What access says, not the answer to a press (#456): it can
              // arrive while the user is anywhere on the form, and scrolling
              // to it would take them, and a focused field, away from where
              // they are. It is still announced.
              reveal: false,
            ),
        ],
      ),
    );
  }
}
