import 'dart:async';

import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The lifetimes a key is offered at a tap, in days (#1028).
const List<int> kExpiryPresets = [30, 90, 180, 365];

/// The error the custom field's check sets on text that isn't a whole number
/// of days in the server's range.
const String _daysError = 'days';

/// The text as a number of days in the server's range, or null.
int? _parseDays(Object? text) {
  final trimmed = text is String ? text.trim() : '';
  if (!RegExp(r'^\d+$').hasMatch(trimmed)) return null;
  final days = int.tryParse(trimmed);
  if (days == null ||
      days < ApiKeyRemoteDataSource.minExpiryDays ||
      days > ApiKeyRemoteDataSource.maxExpiryDays) {
    return null;
  }
  return days;
}

Map<String, dynamic>? _validDays(AbstractControl<dynamic> control) =>
    _parseDays(control.value) == null
    ? <String, dynamic>{_daysError: true}
    : null;

/// The control behind [ExpiryControl]'s custom field (#1028), made by
/// [expiryCustomDaysControl].
///
/// The form that holds the [ExpiryControl] owns it: add it to the form's
/// `FormGroup` under the name the [ExpiryControl] is given, so that the
/// form's own validity and `rejectSubmit` cover it.
///
/// It starts disabled, and the [ExpiryControl] enables it only while "Custom"
/// is chosen. A disabled control is never invalid and is left out of its
/// group's validity, so a preset, or no choice at all, leaves the form valid
/// whatever the field once held. While "Custom" is chosen it holds a whole
/// number of days from [ApiKeyRemoteDataSource.minExpiryDays] to
/// [ApiKeyRemoteDataSource.maxExpiryDays], and an empty field is invalid.
///
/// ## Resetting the form
///
/// A `FormGroup` reset enables every control in it, which would leave this
/// one enabled and empty, so the form invalid, with "Custom" not chosen.
/// Only the [ExpiryControl] enables this control, through [choose]: an
/// enabling that comes from the form is its reset, and ends "Custom".
final class ExpiryCustomDaysControl extends FormControl<String> {
  ExpiryCustomDaysControl()
    : super(disabled: true, validators: [Validators.delegate(_validDays)]);

  final StreamController<void> _resets = StreamController<void>.broadcast();

  /// Whether this class, not the form, is the one changing the control.
  bool _own = false;

  /// Emits when the form was reset while "Custom" was chosen.
  Stream<void> get resets => _resets.stream;

  /// Chooses "Custom": enables the control, holding [text].
  void choose(String? text) {
    _own = true;
    try {
      markAsEnabled();
    } finally {
      _own = false;
    }
    updateValue(text);
  }

  /// Ends "Custom": the control is disabled and empty again.
  ///
  /// Quiet, so a field being taken away isn't heard as something typed. The
  /// form that asked for it is told by the caller.
  void release() {
    _own = true;
    try {
      reset(disabled: true, emitEvent: false);
    } finally {
      _own = false;
    }
  }

  @override
  void markAsEnabled({bool updateParent = true, bool emitEvent = true}) {
    if (_own) {
      super.markAsEnabled(updateParent: updateParent, emitEvent: emitEvent);
      return;
    }
    // The form is resetting, or enabling everything in it: not a choice of
    // "Custom", so the control stays disabled, and a "Custom" chosen ends.
    if (enabled) {
      release();
      _resets.add(null);
    }
  }

  @override
  void dispose() {
    unawaited(_resets.close());
    super.dispose();
  }
}

/// A control for [ExpiryControl]'s custom field. See [ExpiryCustomDaysControl].
FormControl<String> expiryCustomDaysControl() => ExpiryCustomDaysControl();

/// Chooses how many days from now an API key lasts (#1028).
///
/// ## What it shows
///
/// A [label], a row of choices ([kExpiryPresets] and "Custom") and, under
/// them, "Expires {date}" for the day [days] from [now] in the device's own
/// time zone, whenever [days] is set.
///
/// "Custom" shows a field for a whole number of days from
/// [ApiKeyRemoteDataSource.minExpiryDays] to
/// [ApiKeyRemoteDataSource.maxExpiryDays]. A [days] that isn't a preset
/// shows "Custom" chosen with that number in the field. Choosing "Custom"
/// from a preset fills the field with that preset's days, so a valid choice
/// and its date stay on screen while the user edits it; from no choice, the
/// field starts empty.
///
/// ## The custom field belongs to the form
///
/// The field is a control of the enclosing `ReactiveForm`, named
/// [customDaysName] and made by [expiryCustomDaysControl]. The control is
/// enabled while "Custom" is chosen and disabled otherwise, so it makes the
/// form invalid only while it is chosen and holds no valid number, and the
/// form's `rejectSubmit` focuses it as it would any other field.
///
/// ## What it reports
///
/// [onChanged] is asked with the number of days a pick or the field now
/// holds: null while nothing is picked **or** "Custom" is chosen and holds no
/// valid number. The two are told apart by the form: the second makes it
/// invalid. A parent that reads null as "unchanged" must therefore check
/// the form's validity first. It is told nothing about a [days] its parent
/// set.
///
/// The parent owns the value, so a [days] that differs from what was last
/// reported is shown as it is: a parent that refuses a change snaps the
/// control back on its next rebuild. A parent clears the choice, after a
/// save say, by resetting its form and passing null: the reset disables the
/// custom control, which ends "Custom" even when the last report was null.
///
/// ## Announcements
///
/// The chips are read as one group named [label], each as selected or not.
/// The date line is a live region, so a change of pick is said; a rebuild
/// that says the same thing is not.
///
/// ## Read-only, not disabled
///
/// While [readOnly], as while a save is on its way, the chips stay enabled
/// and in the focus order, read as read-only, and ignore a pick; the field
/// is read-only (STYLE_GUIDE, "In-flight forms"). A disabled chip would drop
/// focus.
class ExpiryControl extends StatefulWidget {
  const ExpiryControl({
    required this.days,
    required this.onChanged,
    required this.label,
    required this.customDaysName,
    this.now,
    this.readOnly = false,
    super.key,
  });

  /// The days chosen, or null when nothing is: an edit starts so.
  final int? days;

  /// Asked with the days a pick or the custom field now holds, or null while
  /// nothing is picked or "Custom" holds no valid number.
  final ValueChanged<int?> onChanged;

  /// What the choice is for: "Expires in" on create, "Set a new expiry" on
  /// edit.
  final String label;

  /// The name, in the enclosing `ReactiveForm`, of the control made by
  /// [expiryCustomDaysControl].
  final String customDaysName;

  /// The time the date is counted from; [DateTime.now] when null. For tests.
  final DateTime Function()? now;

  /// Whether nothing changes the choice, as while a save is on its way.
  final bool readOnly;

  @override
  State<ExpiryControl> createState() => _ExpiryControlState();
}

class _ExpiryControlState extends State<ExpiryControl> {
  /// The form's control for the custom field, once found in the form.
  ExpiryCustomDaysControl? _control;
  StreamSubscription<String?>? _typed;
  StreamSubscription<void>? _resets;

  /// Whether "Custom" is the choice, rather than a preset or nothing.
  late bool _custom;

  /// The last days this control reported or took from [ExpiryControl.days],
  /// to tell its parent's echo of a change from a change of the parent's own.
  late int? _known;

  @override
  void initState() {
    super.initState();
    _known = widget.days;
    _custom = _isCustom(widget.days);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(ExpiryControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
    final days = widget.days;
    // The parent says what it was told: nothing to change.
    if (days == _known) return;
    _known = days;
    _custom = _isCustom(days);
    _show(days);
  }

  @override
  void dispose() {
    unawaited(_typed?.cancel());
    unawaited(_resets?.cancel());
    super.dispose();
  }

  static bool _isCustom(int? days) =>
      days != null && !kExpiryPresets.contains(days);

  /// Finds the form's control and follows it, when it is a new one.
  void _bind() {
    final form = ReactiveForm.of(context, listen: false);
    final found = form is FormGroup
        ? form.findControl(widget.customDaysName)
        : null;
    assert(
      found is ExpiryCustomDaysControl,
      'ExpiryControl needs a control named '
      '"${widget.customDaysName}" in the enclosing ReactiveForm, made with '
      'expiryCustomDaysControl().',
    );
    final control = found! as ExpiryCustomDaysControl;
    if (identical(control, _control)) return;
    unawaited(_typed?.cancel());
    unawaited(_resets?.cancel());
    _control = control;
    _typed = control.valueChanges.listen(_onTyped);
    _resets = control.resets.listen((_) => _onReset());
    _show(widget.days);
  }

  /// Puts what [days] is into the control: the field for a custom number, a
  /// disabled, empty control for anything else.
  void _show(int? days) {
    final control = _control!;
    if (_custom) {
      control.choose('$days');
    } else {
      control.release();
    }
  }

  void _onTyped(String? text) {
    // An event for a value the control has since moved on from, as one that
    // enabling it sends, is out of date.
    if (!_custom || text != _control!.value) return;
    final days = _parseDays(text);
    // An error shows as the number is typed, not only once the field is
    // left: a number out of range is wrong the moment it is.
    if (days == null && (text?.trim().isNotEmpty ?? false)) {
      _control!.markAsTouched();
    }
    if (days != _known) _report(days);
  }

  /// The form was reset while "Custom" was chosen.
  void _onReset() {
    if (!_custom || !mounted) return;
    setState(() => _custom = false);
    _known = null;
  }

  void _report(int? days) {
    _known = days;
    widget.onChanged(days);
  }

  void _pickPreset(int days) {
    if (widget.readOnly) return;
    setState(() => _custom = false);
    _control!.release();
    if (days != _known) _report(days);
  }

  void _pickCustom() {
    // Already chosen: what is typed stays.
    if (widget.readOnly || _custom) return;
    final control = _control!;
    // From a preset the field starts at its days; from nothing, empty.
    final from = widget.days;
    setState(() => _custom = true);
    control.choose(from == null ? null : '$from');
    final days = _parseDays(control.value);
    if (days != _known) _report(days);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    const min = ApiKeyRemoteDataSource.minExpiryDays;
    const max = ApiKeyRemoteDataSource.maxExpiryDays;
    final days = widget.days;
    final expires = days == null
        ? null
        : (widget.now ?? DateTime.now)().add(Duration(days: days)).toLocal();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Read as the group's name below, so it isn't read twice.
        ExcludeSemantics(
          child: Text(widget.label, style: theme.textTheme.labelLarge),
        ),
        const BgeGap.sm(),
        Semantics(
          container: true,
          explicitChildNodes: true,
          label: widget.label,
          child: Wrap(
            spacing: tokens.spaceSm,
            runSpacing: tokens.spaceSm,
            children: [
              for (final preset in kExpiryPresets)
                _ExpiryChip(
                  label: l10n.apiKeyExpiryPreset(preset),
                  selected: !_custom && days == preset,
                  readOnly: widget.readOnly,
                  onPick: () => _pickPreset(preset),
                ),
              _ExpiryChip(
                label: l10n.apiKeyExpiryCustom,
                selected: _custom,
                readOnly: widget.readOnly,
                onPick: _pickCustom,
              ),
            ],
          ),
        ),
        if (_custom) ...[
          const BgeGap.md(),
          BgeTextField(
            formControlName: widget.customDaysName,
            label: l10n.apiKeyExpiryCustomField,
            helper: l10n.apiKeyExpiryCustomHelper(min, max),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: widget.readOnly,
            validationMessages: {
              _daysError: (_) => l10n.apiKeyExpiryCustomInvalid(min, max),
            },
          ),
        ],
        if (expires != null) ...[
          const BgeGap.sm(),
          Semantics(
            container: true,
            liveRegion: true,
            child: Text(
              l10n.apiKeyExpiryDate(expires),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A choice chip whose label scales down to fit, and that stays focusable
/// while [readOnly], as `ScopePicker`'s rows do.
///
/// The chip is always given an `onSelected`, so it stays enabled and in the
/// focus order; while [readOnly] a pick does nothing. [IgnorePointer] takes
/// the pointer, so no ripple draws, and the semantic tap, and the focus
/// action, which the node here gives back.
class _ExpiryChip extends StatefulWidget {
  const _ExpiryChip({
    required this.label,
    required this.selected,
    required this.readOnly,
    required this.onPick,
  });

  final String label;
  final bool selected;
  final bool readOnly;
  final VoidCallback onPick;

  @override
  State<_ExpiryChip> createState() => _ExpiryChipState();
}

class _ExpiryChipState extends State<_ExpiryChip> {
  // Owned here so the node can give back the focus action [IgnorePointer]
  // takes while read-only.
  final FocusNode _focusNode = FocusNode(debugLabel: 'ExpiryControl chip');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = widget.readOnly;
    // One node: the chip's merges into this one, which adds what read-only
    // changes.
    return MergeSemantics(
      child: Semantics(
        readOnly: readOnly,
        // As `Focus` has it: withheld on iOS (flutter/flutter#150030).
        onFocus: readOnly && defaultTargetPlatform != TargetPlatform.iOS
            ? _focusNode.requestFocus
            : null,
        child: IgnorePointer(
          ignoring: readOnly,
          child: ChoiceChip(
            focusNode: _focusNode,
            // The label can't wrap in a chip: it scales down to fit instead.
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(widget.label),
            ),
            selected: widget.selected,
            onSelected: (_) {
              if (!readOnly) widget.onPick();
            },
          ),
        ),
      ),
    );
  }
}
