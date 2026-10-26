import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

/// The stale-data banner and its retry, on the overview, each group's page
/// and an event's detail (#497, #498): the collection list's, with this
/// feature's copy.
///
/// One widget for every events screen, as `HouseholdRefreshBanner` is for the
/// household ones. The list's banner and the detail's are the same control
/// over a read the user can ask for again, and copies of it drift apart
/// (#165): a fix to the retry's wording or its accessible name should be
/// made once. What the callers own is what differs: the failed copy (the
/// list's events, or one event), the key their tests address, and how a
/// press reaches their bloc.
///
/// The failed copy names no cause, because neither the hydrate nor the
/// detail read tells one failure from another. While a read the user asked
/// for runs, the button stays in place, disabled, with the in-progress label
/// rather than a bare spinner: a control that disappears mid-interaction
/// moves focus.
class EventRefreshBanner extends StatelessWidget {
  const EventRefreshBanner({
    required this.refreshing,
    required this.failedMessage,
    required this.retryKey,
    this.onRetry,
    super.key,
  });

  /// A read the user asked for is running. One nobody asked for is not
  /// narrated.
  final bool refreshing;

  /// What to say when the last read failed. The in-progress copy is not the
  /// caller's, because "Refreshing…" is the same fact wherever it is shown.
  final String failedMessage;

  /// Key on the retry button, so each screen's tests can address it.
  final Key retryKey;

  /// Asks for the read again, or null where this composition cannot run
  /// one. Absent, the banner still reports the stale data and offers
  /// nothing to press.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final retry = onRetry;

    return BgeInlineBanner(
      tone: refreshing ? BgeBannerTone.info : BgeBannerTone.warning,
      message: refreshing ? l10n.eventsRefreshInProgress : failedMessage,
      // Furniture for as long as the data stays stale, already at the top
      // of the viewport.
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
                    ? l10n.eventsRefreshInProgress
                    : l10n.eventsRefreshRetry,
              ),
            ),
    );
  }
}

/// The retry button's in-flight icon, scaled with the label beside it and
/// silent to a screen reader: the label announces the state.
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
