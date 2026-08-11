import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The primary submit control, with its in-flight treatment built in
/// (#163, #165).
///
/// ```dart
/// BgeSubmitButton(
///   label: l10n.createHouseholdSubmit,
///   progressLabel: l10n.createHouseholdInProgress,
///   submitting: state.isSubmitting,
///   onPressed: _submit,
/// )
/// ```
///
/// ## Why this is one widget rather than a documented pattern
///
/// Four screens each built this shape by hand and all four drifted: two used
/// `FilledButton` and one `ElevatedButton`; the spinner was 16px in two places
/// and 20px in another; one tinted it `onPrimary` and the rest did not. Worse,
/// the accessibility details that make the in-flight state usable — the live
/// region, the retained accessible name — had to be re-remembered every time,
/// and #163 is what happens when one copy forgets a detail the others got
/// right.
///
/// ## The overflow fix is structural
///
/// The progress label is [Flexible] and ellipsizing. Without that, the row of
/// spinner + gap + label overflows its button: measured at **56px over at
/// 320dp**, and **298px over at `textScaler` 2.0** (#163). That combination —
/// a small phone with the OS large-text setting on — is precisely the user the
/// progress label exists to serve. Because the treatment now lives here, no
/// call site can reintroduce it.
///
/// `SemanticsNode.label` carries the full string regardless of visual
/// ellipsis, so nothing is lost to a screen reader.
///
/// ## Accessibility contract
///
/// - **Disabled, never hidden**, while submitting: a control that vanishes
///   mid-interaction moves focus and loses the user's place.
/// - **Keeps an accessible name** while submitting — it swaps [label] for
///   [progressLabel] rather than leaving a bare spinner, which would announce
///   as an unnamed button.
/// - The swap sits in a **live region**, so assistive tech announces the state
///   change instead of only exposing it on next focus.
class BgeSubmitButton extends StatelessWidget {
  /// Creates a submit button.
  const BgeSubmitButton({
    required this.label,
    required this.onPressed,
    this.progressLabel,
    this.submitting = false,
    this.icon,
    this.expand = true,
    super.key,
  });

  /// The button's label at rest.
  final String label;

  /// Invoked on activation. A null value disables the button independently of
  /// [submitting] — for a form that is not yet valid, say.
  final VoidCallback? onPressed;

  /// Label shown while [submitting]. Falls back to [label] when null, which
  /// keeps the accessible name intact; prefer supplying a distinct localized
  /// string ("Creating household…") so the announcement is meaningful.
  final String? progressLabel;

  /// Whether a submission is in flight.
  final bool submitting;

  /// Optional leading icon, shown only at rest — the spinner takes its place
  /// while submitting.
  final IconData? icon;

  /// Whether to stretch to the available width. True by default: submit
  /// buttons sit at the end of a stretched form column.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final effectiveLabel = submitting ? (progressLabel ?? label) : label;

    final button = FilledButton(
      onPressed: submitting ? null : onPressed,
      child: submitting
          ? Semantics(
              liveRegion: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    // Scaled by the ambient text scaler, not a fixed 16.
                    // The spinner sits inline with the label and reads as
                    // part of it, so a fixed size shrinks to a speck beside
                    // doubled text at the 200% scale the app guarantees.
                    // Clamped so it cannot outgrow the button on its own.
                    dimension: MediaQuery.textScalerOf(context)
                        .clamp(maxScaleFactor: BgeTextScale.maxScaleFactor)
                        .scale(tokens.spaceMd),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                  // 8dp: an intra-control gap, deliberately tighter than the
                  // 16dp inter-control rhythm. Resolves the "there is no 12 in
                  // the scale" question from #165 in exactly one place, so the
                  // call sites can no longer disagree about it.
                  const BgeGap.sm(axis: Axis.horizontal),
                  Flexible(
                    child: Text(
                      effectiveLabel,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )
          : _RestingChild(label: label, icon: icon),
    );

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class _RestingChild extends StatelessWidget {
  const _RestingChild({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon == null) return Text(label);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Unscaled, unlike the in-flight spinner: Flutter already grows
        // `Icon` with the text scaler via IconTheme, so scaling here would
        // apply it twice.
        Icon(icon, size: BgeTokens.of(context).spaceMd),
        const BgeGap.sm(axis: Axis.horizontal),
        // Flexible for the same reason as the in-flight row: a long localized
        // label at large text scale overflows a bounded button otherwise.
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}
