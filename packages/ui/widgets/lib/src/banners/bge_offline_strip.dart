import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What [BgeOfflineStrip] shows.
enum BgeOfflineStripState {
  /// Collapsed to nothing: no height, no top inset, no semantics node.
  hidden,

  /// The connection is lost.
  offline,

  /// The connection returned; shown briefly before the host collapses it.
  backOnline,
}

/// A thin notice at the very top of the window that the connection is lost,
/// and, briefly, that it is back (#49).
///
/// Presentation-only: the strings and the state arrive as parameters. The
/// host owns the timing (when to show, how long "Back online" holds) and the
/// layout compensation: while the strip shows it consumes the top window
/// inset, so the host removes that inset from the content below.
///
/// ## Layout
///
/// It paints its own [Material] in `surfaceContainerHigh` (it sits above the
/// navigator, outside any `Scaffold`), and takes the status-bar inset only
/// while it shows. The [SafeArea] sits outside the [AnimatedSize], so the
/// inset switches in the same frame the host switches the content's own: the
/// page below does not jump at either transition. While `hidden` it takes no
/// height at all, so a screen's own inset is the only one.
///
/// ## Colour
///
/// Both messages are in `BgeStatusColors.offline` (`onSurfaceVariant`), which
/// the scheme tests cover on every surface role. "Back online" would read as
/// `BgeStatusColors.synced` (`secondary`), but that is under 7:1 as text on
/// `surfaceContainerHigh` in both high-contrast schemes, so only its icon is
/// `synced` (3:1 for non-text is enough, and the tokens tests pin it).
///
/// ## Accessibility
///
/// - One merged live-region node over icon and text, in the order
///   `UnverifiedSessionBanner` documents: [MergeSemantics] outside,
///   [Semantics] inside.
/// - `offline` and `backOnline` are the same element, so the change of label
///   is what announces. A fresh node would announce too, but a collapsed
///   strip would lose the user's place between the two.
/// - Not focusable and no action: a notice, not a control. Nothing moves
///   focus.
/// - Size changes resolve through `BgeMotion.durationOf`, so reduced motion
///   makes them instant (and takes [AnimatedSize] out, which cannot run for
///   zero time).
class BgeOfflineStrip extends StatelessWidget {
  const BgeOfflineStrip({
    required this.state,
    required this.offlineMessage,
    required this.backOnlineMessage,
    super.key,
  });

  final BgeOfflineStripState state;

  /// Localized, e.g. "You're offline. Changes will sync when you reconnect."
  final String offlineMessage;

  /// Localized, e.g. "Back online".
  final String backOnlineMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final statuses = BgeStatusColors.of(context);

    final Widget content;
    if (state == BgeOfflineStripState.hidden) {
      content = const SizedBox.shrink();
    } else {
      final status = state == BgeOfflineStripState.offline
          ? BgeStatus.offline
          : BgeStatus.synced;
      final message = state == BgeOfflineStripState.offline
          ? offlineMessage
          : backOnlineMessage;
      content = Padding(
        padding: EdgeInsets.symmetric(
          vertical: tokens.spaceSm,
          horizontal: tokens.spaceMd,
        ),
        child: MergeSemantics(
          child: Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Icon(
                  BgeStatusColors.iconFor(status),
                  color: statuses.colorFor(status),
                ),
                const BgeGap.sm(axis: Axis.horizontal),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: statuses.offline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // A zero-duration [AnimatedSize] finishes inside its own layout and
    // re-dirties itself, which asserts. Under reduced motion there is nothing
    // to animate, so the size change is simply the layout.
    final duration = BgeMotion.durationOf(context, tokens.motionShort);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: state != BgeOfflineStripState.hidden,
        bottom: false,
        child: duration == Duration.zero
            ? content
            : AnimatedSize(
                duration: duration,
                curve: BgeMotion.enter,
                alignment: Alignment.topCenter,
                child: content,
              ),
      ),
    );
  }
}
