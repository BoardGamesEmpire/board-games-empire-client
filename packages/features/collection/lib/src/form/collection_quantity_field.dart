import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_collection/l10n/game_collection_localizations.dart';

/// The copies field between a minus and a plus button (#45, #46).
///
/// Package-private: the add and edit sheets share it. It binds to a
/// `FormControl<String>` named [formControlName] and reads the copies from
/// it, so a step starts from what was typed. A value that isn't a whole
/// number from 1 can't be stepped down, and steps up to 1. Plus stops at
/// [max]. Validation stays with the sheet's form.
///
/// A button at its limit stays enabled and does nothing, so one pressed down
/// to its limit keeps the focus. Its semantics say it is disabled. After a
/// step a hidden live region says the copies now in the field, since the
/// field itself isn't focused to be read.
class CollectionQuantityField extends StatefulWidget {
  const CollectionQuantityField({
    required this.formControlName,
    required this.max,
    required this.busy,
    required this.fieldKey,
    required this.decreaseKey,
    required this.increaseKey,
    required this.label,
    required this.validationMessages,
    super.key,
  });

  /// What was typed, read as copies: a whole number from 1, or null. The
  /// sheets' validators read it the same way.
  static int? parseCopies(Object? typed) {
    final copies = typed is String ? int.tryParse(typed.trim()) : null;
    return copies != null && copies >= 1 ? copies : null;
  }

  final String formControlName;

  /// The largest value the field takes, which plus can't step past.
  final int max;

  /// Whether a write is under way, when neither button steps and the field
  /// is read-only.
  final bool busy;

  /// The keys of the text field and of its minus and plus buttons.
  final Key fieldKey;
  final Key decreaseKey;
  final Key increaseKey;

  final String label;

  /// The messages for the errors the sheet's validator sets on the control.
  final Map<String, String Function(Object)> validationMessages;

  @override
  State<CollectionQuantityField> createState() =>
      _CollectionQuantityFieldState();
}

class _CollectionQuantityFieldState extends State<CollectionQuantityField> {
  /// The copies the last step left in the field, which the live region says
  /// while the field still holds them.
  int? _stepped;

  void _step(AbstractControl<String> control, int copies) {
    control
      ..value = '$copies'
      ..markAsTouched();
    setState(() => _stepped = copies);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);

    return ReactiveValueListenableBuilder<String>(
      formControlName: widget.formControlName,
      builder: (context, control, _) {
        final copies = CollectionQuantityField.parseCopies(control.value);
        final stepped = copies != null && copies == _stepped ? copies : null;
        final max = widget.max;
        final canDecrease = !widget.busy && copies != null && copies > 1;
        // A value that isn't a number steps to 1, which must fit too.
        final canIncrease =
            !widget.busy && (copies == null ? max >= 1 : copies < max);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StepButton(
              key: widget.decreaseKey,
              icon: Icons.remove,
              label: l10n.addToCollectionQuantityDecrease,
              onStep: canDecrease ? () => _step(control, copies - 1) : null,
            ),
            Expanded(
              child: BgeTextField(
                key: widget.fieldKey,
                formControlName: widget.formControlName,
                label: widget.label,
                keyboardType: TextInputType.number,
                readOnly: widget.busy,
                validationMessages: widget.validationMessages,
              ),
            ),
            _StepButton(
              key: widget.increaseKey,
              icon: Icons.add,
              label: l10n.addToCollectionQuantityIncrease,
              onStep: canIncrease
                  ? () => _step(control, copies == null ? 1 : copies + 1)
                  : null,
            ),
            if (stepped != null)
              _SteppedAnnouncement(
                message: l10n.addToCollectionQuantityStepped(stepped),
              ),
          ],
        );
      },
    );
  }
}

/// A minus or plus button, at least a tap target square.
///
/// At its limit, [onStep] is null and the button stays enabled but does
/// nothing: a disabled button gives up the focus, so stepping down to 1
/// would drop it. Its look and its semantics say it is disabled. The node is
/// named in its label, not by the tooltip, which iOS doesn't read as a name.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.label,
    required this.onStep,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onStep;

  static void _ignore() {}

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final onStep = this.onStep;

    return Semantics(
      container: true,
      button: true,
      enabled: onStep != null,
      label: label,
      onTap: onStep,
      excludeSemantics: true,
      child: SizedBox(
        width: tokens.minTapTarget,
        height: tokens.minTapTarget,
        child: IconButton(
          icon: Icon(icon),
          tooltip: label,
          color: onStep == null ? Theme.of(context).disabledColor : null,
          onPressed: onStep ?? _ignore,
        ),
      ),
    );
  }
}

/// Says the copies a step left in the field to a screen reader, and shows
/// nothing.
class _SteppedAnnouncement extends StatelessWidget {
  const _SteppedAnnouncement({required this.message});

  /// The smallest box whose semantics node survives: an empty rect's can be
  /// dropped. Not a spacing decision.
  static const double _anchorExtent = 1;

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: message,
    child: const SizedBox(width: _anchorExtent, height: _anchorExtent),
  );
}
