import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A line under a form field that says something about the value it holds,
/// such as who a chosen reach shows the profile to (#547).
///
/// Follows the control named [formControlName]: [noteFor] gives the line for
/// its value, or null for none, and then nothing is drawn, the gap above it
/// included.
///
/// The line is a live region, so a screen reader says it as it changes. A
/// menu's items carry a label only, and the menu that takes focus back after
/// a pick doesn't say the line, so without the live region a pick would
/// change it unheard.
class BgeFieldNote<T> extends StatelessWidget {
  /// Creates the note [noteFor] gives for [formControlName]'s value.
  const BgeFieldNote({
    required this.formControlName,
    required this.noteFor,
    this.textKey,
    super.key,
  });

  /// The control whose value the line describes.
  final String formControlName;

  /// The line for a value, or null for none.
  final String? Function(T? value) noteFor;

  /// Key on the line's text, so a test can find it.
  final Key? textKey;

  @override
  Widget build(BuildContext context) => ReactiveValueListenableBuilder<T>(
    formControlName: formControlName,
    builder: (context, control, _) {
      final note = noteFor(control.value);
      if (note == null) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const BgeGap.sm(),
          Semantics(
            container: true,
            liveRegion: true,
            child: Text(
              note,
              key: textKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    },
  );
}
