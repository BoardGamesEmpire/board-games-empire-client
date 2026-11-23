import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The in-flight icon of a refresh control: the treatment `BgeSubmitButton`
/// gives its own spinner, and mute to a screen reader — the control's label is
/// what announces the state.
///
/// Shared by the banner's retry and `BgeRefreshButton`, so the two spinners
/// that stand for one pass look alike (#314).
class RefreshSpinner extends StatelessWidget {
  /// Beside a text label, as in the banner's retry: a `spaceMd` square scaled
  /// by the ambient text scaler rather than a fixed 16. The spinner sits
  /// inline with the label and reads as part of it, so a fixed size shrinks to
  /// a speck beside doubled text at the 200% scale the app guarantees (#32).
  const RefreshSpinner({super.key}) : _inIconSlot = false;

  /// In place of an icon, as in an icon button: the size of the ambient
  /// [IconTheme], so the spinner fills the slot the icon left and the button
  /// keeps its look while a pass runs.
  const RefreshSpinner.icon({super.key}) : _inIconSlot = true;

  final bool _inIconSlot;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: _inIconSlot
          ? IconTheme.of(context).size!
          : BgeTextScale.clampedOf(
              context,
            ).scale(BgeTokens.of(context).spaceMd),
      child: const CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}
