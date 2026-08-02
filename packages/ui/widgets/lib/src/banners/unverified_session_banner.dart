import 'package:flutter/material.dart';

/// Passive notice that the current session was restored from local material
/// without server confirmation (#98).
///
/// Presentation-only, per the ui/widgets convention: strings arrive as
/// parameters (this package has no localization dependency), visibility is
/// a parameter (this package knows nothing about auth state), and the
/// widget gates nothing — offline-first means the app keeps working, so the
/// banner informs rather than restricts.
///
/// ## Accessibility
///
/// - The appearance reaches assistive technology through a **live region**
///   on the message node, not an explicit announcement.
///   `SemanticsService.announce` is deprecated, and on Android — the
///   primary target — announcement events themselves are deprecated
///   because they force TalkBack to clear its speech queue; the platform's
///   own guidance is to let a [Semantics] live region trigger the readout
///   implicitly. A live region announces when its node appears or its
///   label changes: the label here is static and the intended host mounts
///   this widget ABOVE the shell navigator (so route changes do not
///   recreate the node), which yields exactly one readout per episode —
///   on appearance — and a fresh one when a new episode recreates the
///   node.
/// - Nothing here moves focus. The user was doing something when
///   connectivity was lost; yanking them to a banner would compound the
///   interruption. Live regions are announce-only by design.
/// - The dismiss control is a standard [IconButton]: ≥48dp touch target,
///   focusable, activatable by keyboard, with [dismissLabel] as both its
///   tooltip and its semantic label.
/// - The message and icon merge into a single semantics node so a screen
///   reader traverses one meaningful stop, not a decorative icon and then
///   a sentence.
///
/// ## Dismissal
///
/// The dismiss control reports through [onDismiss]; whether the banner is
/// then hidden — and for how long — is the HOST's decision, expressed back
/// through [visible]. Ownership sits with the host deliberately: the host
/// also compensates layout for the banner's presence (it consumes the top
/// window inset, so the host removes that inset from the content below —
/// see `MediaQuery.removePadding` at the call site). Visibility and layout
/// compensation must be decided by the same owner, or a banner-internal
/// dismissal leaves the content underlapping the status bar with the host
/// none the wiser. The intended host policy is per-episode: dismissal
/// rearms when a new unverified episode begins.
class UnverifiedSessionBanner extends StatelessWidget {
  const UnverifiedSessionBanner({
    required this.visible,
    required this.message,
    required this.dismissLabel,
    required this.onDismiss,
    super.key,
  });

  /// Whether the banner renders. The (re)appearing live-region node is
  /// what assistive technology reads out — no imperative announce.
  final bool visible;

  /// Localized body text, e.g. "Can't reach the server — using your saved
  /// sign-in."
  final String message;

  /// Localized label for the dismiss control (tooltip + semantics).
  final String dismissLabel;

  /// Invoked when the user activates the dismiss control. The host owns
  /// what dismissal means (see the class docs).
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;

    // Material ancestor is provided here rather than assumed: the banner is
    // hosted ABOVE the shell navigator, outside any route's Scaffold.
    return Material(
      color: colorScheme.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          child: Row(
            children: [
              Expanded(
                // Live region on the merged message node: assistive tech
                // reads it when the node appears (see the class docs for
                // why this replaces an explicit announcement). Merging
                // keeps it ONE traversal stop — icon and sentence together.
                //
                // Nesting order is load-bearing: [MergeSemantics] OUTSIDE,
                // the [Semantics] annotation INSIDE. MergeSemantics forms
                // the merge-boundary node and folds every descendant
                // annotation into it — including this liveRegion flag — so
                // flag and label land on the SAME node. Inverted (Semantics
                // outside MergeSemantics), the flag sits on a parent node
                // while the label lives on the boundary node below it: a
                // live region with no text to read, above a message that is
                // not a live region.
                child: MergeSemantics(
                  child: Semantics(
                    liveRegion: true,
                    child: Row(
                      children: [
                        Icon(
                          Icons.cloud_off_outlined,
                          color: colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              message,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: colorScheme.onTertiaryContainer,
                                  ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: onDismiss,
                tooltip: dismissLabel,
                icon: Icon(
                  Icons.close,
                  color: colorScheme.onTertiaryContainer,
                  semanticLabel: dismissLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
