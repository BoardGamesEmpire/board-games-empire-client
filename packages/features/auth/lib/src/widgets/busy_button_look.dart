import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

// The look of a button that is enabled but does nothing on a press, as a
// `BgeInertButton` leaves to its caller: the provider sign-in buttons (#583)
// and the Sign-in methods screen's Link and Unlink (#582) share it.

/// No answer to a press or a hover, as `BgeShelf`'s button at an end has
/// none, and when [muted], drawn as a disabled button is. A busy button, the
/// one whose own press is out, isn't muted: it keeps its colours, since its
/// label says why a press does nothing. The focus overlay stays: it is how a
/// keyboard user sees where they are.
ButtonStyle inertButtonStyle(BuildContext context, {required bool muted}) {
  final disabled = Theme.of(context).disabledColor;
  return ButtonStyle(
    foregroundColor: muted ? WidgetStatePropertyAll(disabled) : null,
    iconColor: muted ? WidgetStatePropertyAll(disabled) : null,
    side: muted ? WidgetStatePropertyAll(BorderSide(color: disabled)) : null,
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? null
          : disabled.withValues(alpha: 0),
    ),
    mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.basic),
    splashFactory: NoSplash.splashFactory,
    enableFeedback: false,
  );
}

/// A busy button's icon: a spinner scaled with the label beside it, in the
/// button's icon colour, and mute to a screen reader, since the button's
/// name says it is busy.
class BusyButtonSpinner extends StatelessWidget {
  const BusyButtonSpinner({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: BgeTextScale.clampedOf(
        context,
      ).scale(BgeTokens.of(context).spaceMd),
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: IconTheme.of(context).color,
      ),
    ),
  );
}
