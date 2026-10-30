import 'package:flutter/widgets.dart';

/// Edge length of the box that carries the error announcement's semantics.
///
/// **Not a spacing decision, which is why it is named rather than inline.** A
/// semantics node with an empty rect can be dropped when the tree is compiled,
/// and a dropped node announces nothing; this is the smallest box that is
/// guaranteed to survive. `SizedBox.shrink()` does not.
///
/// Naming it also removes the need for a file-wide `spacing` exemption in
/// `design_system_enforcement_test.dart`. A blanket exemption would have kept
/// itself alive on the strength of this one anchor while waving through every
/// future literal `SizedBox` in the file.
const double _semanticsAnchorExtent = 1;

/// A visually-imperceptible node that announces a field's validation error as
/// it appears: it announces [message], and is nothing while that is null.
/// Deliberately 1x1 rather than zero-size — see [_semanticsAnchorExtent].
///
/// The announcement rides a [Semantics.label] on a 1×1 box rather than
/// rendering invisible text. An earlier version drew a real `Text` at
/// `fontSize: 0` inside an `OverflowBox` — which put a raw font size in the
/// widget tree purely to hide something, and is the kind of trick that gets
/// "cleaned up" by someone who does not realize it is load-bearing.
///
/// ## Why a field's builder places it, with the field's `errorText`
///
/// A `ReactiveFormField`'s state rebuilds on the control's status **and** its
/// touch, and its `errorText` is the text the field draws. Placed in that
/// builder, this announces what is drawn, when it is drawn, with no
/// subscriptions of its own.
///
/// Both rebuilds matter. The auth-feature original sat under a
/// `ReactiveFormConsumer`, which rebuilds on value and status but not touch, so
/// it **never fired** in the flow that produces errors: submitting an empty
/// form calls `markAllAsTouched()`, the control goes from untouched-invalid to
/// touched-invalid, and nothing was announced.
///
/// Its successor subscribed to both streams itself, and composed the message
/// from the field's `validationMessages` alone, so an error the field drew
/// from `ReactiveFormConfig` or as its bare key was never announced. It also
/// had to be handed the field's resolved control, or it went on announcing for
/// a group swapped away (#186). Reading `errorText` inside the field's own
/// builder leaves nothing to drift.
class LiveErrorRegion extends StatelessWidget {
  const LiveErrorRegion({required this.message, super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    if (message == null) return const SizedBox.shrink();

    return Semantics(
      liveRegion: true,
      label: message,
      child: const SizedBox(
        width: _semanticsAnchorExtent,
        height: _semanticsAnchorExtent,
      ),
    );
  }
}
