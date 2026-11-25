import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A form's one filled button on the API key pages (#1028): Create on the
/// page that makes a key, Save changes on a key's own page. While what it
/// sent is on its way it stays enabled and ignores presses, so it keeps
/// focus, and its name, [busyLabel], says what it is doing (STYLE_GUIDE §5).
///
/// It draws as `BgeSubmitButton` does, at rest and busy, but that button
/// disables itself while busy, and a disabled button can't hold focus: the
/// press that opened a question, or sent the form, would lose its place. This
/// one is a [BgeInertButton], whose one semantics node is the same at rest
/// and busy, so nothing a screen reader or a browser holds is replaced under
/// it.
///
/// Its node is a live region while [busy], so [busyLabel] is said as it
/// starts, and not at rest, so that [label] coming back after a failure isn't
/// read over the failure's banner.
///
/// A null [onPressed] disables it, as offline, or while another write no
/// press of its own started is on its way.
class ApiKeySubmitButton extends StatelessWidget {
  const ApiKeySubmitButton({
    required this.label,
    required this.busyLabel,
    required this.busy,
    required this.onPressed,
    this.onFocusNode,
    this.buttonKey,
    super.key,
  });

  /// Its name at rest.
  final String label;

  /// Its name while [busy].
  final String busyLabel;

  /// Whether what it sent is on its way.
  final bool busy;

  /// Checks the form, asks what needs asking, and sends it. Null disables
  /// the button.
  final VoidCallback? onPressed;

  /// Given the button's focus node as it is built, so a press can give it
  /// focus before a question opens, for the question to hand it back.
  final ValueChanged<FocusNode>? onFocusNode;

  /// On the `FilledButton` itself, for a test to find it by.
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final label = busy ? busyLabel : this.label;

    // Merged into one node with the button's, by a `BgeOnlineOnly` above.
    return Semantics(
      liveRegion: busy,
      // Disabled, the merged node says so itself, as `BgeOnlineOnly` has it
      // offline: Flutter's text-contrast guideline reads a node's own flags,
      // and would otherwise hold the dimmed label to 4.5:1, which WCAG 1.4.3
      // exempts. What a screen reader hears doesn't change.
      enabled: onPressed == null ? false : null,
      child: BgeInertButton(
        inert: busy,
        label: label,
        onPressed: onPressed,
        builder: (context, focusNode, onPressed) {
          onFocusNode?.call(focusNode);
          return SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: buttonKey,
              focusNode: focusNode,
              onPressed: onPressed,
              child: busy ? _Busy(label: label) : Text(label),
            ),
          );
        },
      ),
    );
  }
}

/// The busy face: a spinner beside the label, which is cut short with an
/// ellipsis before it overflows the button at a large text size.
class _Busy extends StatelessWidget {
  const _Busy({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(
        // Scaled with the label it sits beside.
        dimension: BgeTextScale.clampedOf(
          context,
        ).scale(BgeTokens.of(context).spaceMd),
        child: CircularProgressIndicator(
          strokeWidth: 2,
          // The button's own foreground: it is drawn enabled.
          color: IconTheme.of(context).color,
        ),
      ),
      const BgeGap.sm(axis: Axis.horizontal),
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
    ],
  );
}
