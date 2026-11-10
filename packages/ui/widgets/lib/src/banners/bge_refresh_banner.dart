import 'package:flutter/material.dart';
import 'package:ui/src/banners/bge_inline_banner.dart';
import 'package:ui/src/buttons/bge_inert_button.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The stale-data banner and the retry that shares it (#269, #300, #573).
///
/// One widget for every cached list and detail screen, and for both of the
/// states each of them can be in. Their banners are the same control over
/// the same kind of pass and the same status: copies drifted apart once
/// already (#165 is what that costs), and a fix to the retry's wording or
/// its accessible name should not have to be made more than once.
///
/// What the callers own is what genuinely differs: the failed copy (a list
/// "may be out of date", one record "may be"), the key their tests address,
/// and how a press reaches their own bloc. The strings arrive localized.
///
/// ## What it says, and what it will not say
///
/// The failed copy names **no cause**. A hydrate's outcome collapses every
/// failure the drain can hit — an unreachable server, a 4xx, an unparseable
/// body — and the first real one in the wild was a reachable server
/// answering 400. Naming a cause the screen cannot know sends people to
/// check their network while the fault is in the response. That is also why
/// the button offers another attempt and promises nothing.
///
/// Warning tone at rest, info while refreshing: at rest something is
/// wrong, and mid-refresh something is being done about it.
///
/// ## The button keeps its place and its name
///
/// While the pass runs the button is **enabled and inert, not removed and
/// not disabled**, and its label swaps to the in-progress string rather than
/// leaving a bare spinner. That is the place-and-name half of
/// `BgeSubmitButton`'s "Disabled, never hidden" contract (#163), which exists
/// because a control that vanishes mid-interaction moves focus, and an
/// unlabelled one announces as "button, disabled" with no reason given. The
/// disabled half is left out on purpose, below.
///
/// It is not disabled because `ButtonStyleButton` passes
/// `canRequestFocus: enabled`: a disabled button gives up focus, so a
/// keyboard or screen-reader user who pressed it lost their place on every
/// pass (#607). Instead it is a [BgeInertButton]: a press while [refreshing]
/// does nothing, and the retry has its own semantics node: it reads as in
/// progress (focusable, not enabled, with no tap action) and is the same node
/// at rest and busy, so a screen reader's cursor is not moved when the pass
/// starts or ends. A held Enter or Space starts one pass, not one per key
/// repeat.
///
/// [refreshing] is only ever true for a pass the **user asked for**
/// (#300). A pass a background trigger started is not narrated: the banner
/// clears when it succeeds, and nothing announces it while it runs.
class BgeRefreshBanner extends StatelessWidget {
  const BgeRefreshBanner({
    required this.failedMessage,
    required this.inProgressLabel,
    required this.retryLabel,
    required this.retryKey,
    this.refreshing = false,
    this.onRetry,
    super.key,
  });

  /// What to say when the last pass failed. Screen-specific; the
  /// in-progress copy is not, because "Refreshing…" is the same fact
  /// wherever it is shown.
  final String failedMessage;

  /// Says a pass is running, as the banner's message and as the retry's
  /// label while it runs.
  final String inProgressLabel;

  /// The retry button's label at rest.
  final String retryLabel;

  /// Key on the retry button, so each screen's tests can address it.
  final Key retryKey;

  /// A pass the user asked for is running.
  final bool refreshing;

  /// Dispatches the retry, or null where this composition cannot run a
  /// pass at all — in which case the banner still reports the stale data
  /// and simply offers nothing to press.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final retry = onRetry;

    return BgeInlineBanner(
      tone: refreshing ? BgeBannerTone.info : BgeBannerTone.warning,
      message: refreshing ? inProgressLabel : failedMessage,
      // Furniture for as long as the data stays stale, and it already sits
      // at the top of the viewport.
      reveal: false,
      action: retry == null
          ? null
          : _Retry(
              retryKey: retryKey,
              refreshing: refreshing,
              inProgressLabel: inProgressLabel,
              retryLabel: retryLabel,
              onRetry: retry,
            ),
    );
  }
}

/// The retry button, enabled through a pass so it keeps focus (#607).
class _Retry extends StatelessWidget {
  const _Retry({
    required this.retryKey,
    required this.refreshing,
    required this.inProgressLabel,
    required this.retryLabel,
    required this.onRetry,
  });

  final Key retryKey;
  final bool refreshing;
  final String inProgressLabel;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final label = refreshing ? inProgressLabel : retryLabel;

    return BgeInertButton(
      inert: refreshing,
      label: label,
      onPressed: onRetry,
      builder: (context, focusNode, onPressed) => TextButton.icon(
        key: retryKey,
        focusNode: focusNode,
        onPressed: onPressed,
        icon: refreshing ? const _RetrySpinner() : const Icon(Icons.refresh),
        label: Text(label),
      ),
    );
  }
}

/// The retry button's in-flight icon: the treatment `BgeSubmitButton` gives
/// its own spinner, and mute to a screen reader — the button's label is what
/// announces the state.
///
/// A `spaceMd` square scaled by the ambient text scaler rather than a fixed
/// 16. The spinner sits inline with the label and reads as part of it, so a
/// fixed size shrinks to a speck beside doubled text at the 200% scale the
/// app guarantees (#32).
class _RetrySpinner extends StatelessWidget {
  const _RetrySpinner();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: BgeTextScale.clampedOf(context)
          .scale(BgeTokens.of(context).spaceMd),
      child: const CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}
