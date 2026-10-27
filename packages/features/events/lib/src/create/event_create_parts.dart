import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';

// The pieces the create form's sections share (#499), so each is built, and
// its reasons given, once.

/// A section's heading on the create form, announced as one.
class EventCreateHeading extends StatelessWidget {
  const EventCreateHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// A note's style on the create form: body text in the theme's quieter
/// color, so it reads as said about the fields rather than as one of them.
TextStyle? eventCreateQuiet(ThemeData theme) => theme.textTheme.bodyMedium
    ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

/// One of the create form's menus, bound to [formControlName] or to
/// [formControl], with [label] on its field. [hint] shows while it holds
/// nothing, as a default the server applies to a choice left untouched.
///
/// It takes its field's width and wraps a long choice whole. At 320dp and
/// 2.0 text, a menu sized to its longest choice overflowed, and a dense one
/// cut "Anyone attending adds them" to "Anyone" (measured). Not dense costs
/// a taller field at 1.0.
class EventCreateMenu<T> extends StatelessWidget {
  const EventCreateMenu({
    required this.label,
    required this.items,
    required this.readOnly,
    this.formControlName,
    this.formControl,
    this.hint,
    super.key,
  });

  final String label;
  final List<DropdownMenuItem<T>> items;

  /// Whether nothing here takes an edit: the menu doesn't open.
  final bool readOnly;

  final String? formControlName;
  final FormControl<T>? formControl;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final hint = this.hint;

    return ReactiveDropdownField<T>(
      formControlName: formControlName,
      formControl: formControl,
      readOnly: readOnly,
      isExpanded: true,
      isDense: false,
      decoration: InputDecoration(labelText: label),
      hint: hint == null ? null : Text(hint),
      items: items,
    );
  }
}

/// A menu item for each of [values] that [labelOf] names, in their order.
/// `unknown` has no label, so it is never offered.
List<DropdownMenuItem<T>> eventCreateMenuItems<T>(
  Iterable<T> values,
  String? Function(T value) labelOf,
) => [
  for (final value in values)
    if (labelOf(value) case final label?)
      DropdownMenuItem(value: value, child: Text(label)),
];
