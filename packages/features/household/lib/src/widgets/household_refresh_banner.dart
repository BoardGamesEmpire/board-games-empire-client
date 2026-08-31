import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

/// The stale-data banner and the retry that shares it (#269 D2, #300).
///
/// One widget for both household screens and for both of the states each
/// of them can be in. The list's banner and the detail's are the same
/// control over the same pass and the same status: two copies drifted
/// apart once already (#165 is what that costs), and a fix to the retry's
/// wording or its accessible name should not have to be made twice.
///
/// What the callers own is what genuinely differs: the failed copy (a list
/// "may be out of date", one household "may be"), the key their tests
/// address, and how a press reaches their own bloc.
///
/// ## What it says, and what it will not say
///
/// The failed copy names **no cause**. `HydrateOutcome.failed` collapses
/// every failure the drain can hit — an unreachable host, a 4xx, an
/// unparseable body — and the first real one in the wild was a reachable
/// server answering 400. Naming a cause the screen cannot know sends
/// people to check their network while the fault is in the response. That
/// is also why the button offers another attempt and promises nothing.
///
/// Warning tone at rest, info while refreshing: at rest something is
/// wrong, and mid-refresh something is being done about it.
///
/// ## The button keeps its place and its name
///
/// While the pass runs the button is **disabled, not removed**, and its
/// label swaps to the in-progress string rather than leaving a bare
/// spinner — `BgeSubmitButton`'s contract (#163), which exists because a
/// control that vanishes mid-interaction moves focus, and an unlabelled
/// one announces as "button, disabled" with no reason given.
///
/// [refreshing] is only ever true for a pass the **user asked for**
/// (#300 D6). A pass a #302 trigger started is not narrated: the banner
/// clears when it succeeds, and nothing announces it while it runs.
class HouseholdRefreshBanner extends StatelessWidget {
  const HouseholdRefreshBanner({
    required this.failedMessage,
    required this.retryKey,
    this.refreshing = false,
    this.onRetry,
    super.key,
  });

  /// What to say when the last pass failed. Screen-specific; the
  /// refreshing copy is not, because "Refreshing…" is the same fact
  /// wherever it is shown.
  final String failedMessage;

  /// Key on the retry button, so each screen's tests can address it.
  final Key retryKey;

  /// A pass the user asked for is running.
  final bool refreshing;

  /// Dispatches the retry, or null where this composition cannot run a
  /// pass at all (web until #125) — in which case the banner still reports
  /// the stale data and simply offers nothing to press.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final retry = onRetry;

    return BgeInlineBanner(
      tone: refreshing ? BgeBannerTone.info : BgeBannerTone.warning,
      message: refreshing ? l10n.householdRefreshInProgress : failedMessage,
      // Furniture for as long as the data stays stale, and it already sits
      // at the top of the viewport.
      reveal: false,
      action: retry == null
          ? null
          : TextButton.icon(
              key: retryKey,
              onPressed: refreshing ? null : retry,
              icon: refreshing
                  ? const _RetrySpinner()
                  : const Icon(Icons.refresh),
              label: Text(
                refreshing
                    ? l10n.householdRefreshInProgress
                    : l10n.householdRefreshRetry,
              ),
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
