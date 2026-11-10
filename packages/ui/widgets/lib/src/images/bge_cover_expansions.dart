import 'package:flutter/material.dart';
import 'package:ui/src/focus/bge_focus_ring.dart';
import 'package:ui/src/focus/bge_pointer_focus.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What a base game's cover says about its expansions (#711): how many there
/// are, whether they are shown, and the words for both.
///
/// Given to `BgeCoverTile.expansions`, which draws a badge for them at the
/// bottom end of the cover: a button of its own, after the cover, that calls
/// [onToggle]. The cover offers the same toggle as a custom action, for a
/// screen reader on the cover. The words are the caller's, as every string
/// in this package is.
final class BgeCoverExpansions {
  /// Describes [count] expansions, shown while [expanded].
  const BgeCoverExpansions({
    required this.count,
    required this.expanded,
    required this.onToggle,
    required this.label,
    required this.showLabel,
    required this.hideLabel,
  }) : assert(count > 0, 'a cover with no expansions has no badge');

  /// How many expansions there are, drawn on the badge.
  final int count;

  /// Whether the expansions are shown, which the badge announces as its
  /// expanded state.
  final bool expanded;

  /// Shows the expansions while they are hidden, and hides them while they
  /// are shown.
  final VoidCallback onToggle;

  /// The badge's accessible name, such as "Wingspan expansions, 2". Its
  /// expanded state says whether they are shown, so the name doesn't.
  final String label;

  /// The cover's custom action while the expansions are hidden, such as
  /// "Show expansions".
  final String showLabel;

  /// The cover's custom action while the expansions are shown, such as
  /// "Hide expansions".
  final String hideLabel;
}

/// The badge `BgeCoverTile` draws for its [BgeCoverExpansions] (#711).
///
/// Not exported: the tile places it, at the bottom end of the picture.
///
/// A tonal button, in the tertiary container colours, with a puzzle piece and
/// the count. It is unlike `BgeStackMarker`'s badge on purpose, which sits at
/// the top end, in the secondary colours, with a number alone: the two can be
/// on one cover, and they count different things.
///
/// ## Size
///
/// At least [BgeTokens.minTapTarget] square, and drawn as big as it takes
/// presses. A smaller badge with a larger, invisible target would take
/// presses aimed at the cover beside it. The whole of its box takes them,
/// rounded corners included: the fill is painted as ink on a `Material` with
/// no shape, because a shaped one hit-tests against its shape and would send
/// a press near a corner to the cover underneath, opening the game. The count
/// grows with the text, and the icon, which the count and the name already
/// say, doesn't, so that a two-digit count still leaves most of a phone's
/// cover.
///
/// ## Focus
///
/// As the cover's own: a tap gives the badge focus before it toggles, so
/// that a keyboard user who goes on from there starts at the badge, and its
/// [BgeFocusRing] stays hidden while the focus is a pointer's
/// ([BgePointerFocus]). The ring sits [BgeTokens.focusRingGap] outside the
/// badge, as on a tonal button, in room the badge leaves at the cover's edge,
/// so it stays inside the cover.
///
/// [focusNode] is the tile's, so that the tile can give focus to the cover
/// when the badge goes while it holds it.
///
/// ## Semantics
///
/// One node: a button named by [BgeCoverExpansions.label], with an expanded
/// state, and the ink's tap and focus. The count and the icon are drawn only.
class BgeCoverExpansionsBadge extends StatefulWidget {
  /// Creates the badge for [expansions], taking focus with [focusNode].
  const BgeCoverExpansionsBadge({
    required this.expansions,
    required this.focusNode,
    super.key,
  });

  /// What the badge counts and toggles.
  final BgeCoverExpansions expansions;

  /// The badge's focus, which its owner disposes.
  final FocusNode focusNode;

  @override
  State<BgeCoverExpansionsBadge> createState() =>
      _BgeCoverExpansionsBadgeState();
}

class _BgeCoverExpansionsBadgeState extends State<BgeCoverExpansionsBadge>
    with BgePointerFocus<BgeCoverExpansionsBadge> {
  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final expansions = widget.expansions;
    final focusNode = widget.focusNode;
    final radius = BorderRadius.circular(tokens.radiusMd);
    // The ring's gap and its stroke, kept clear around the badge.
    final ringReach = tokens.focusRingGap + tokens.focusOutlineWidth;

    // MergeSemantics so that the name, the state and the ink's tap and focus
    // are one node, as the cover's are.
    return MergeSemantics(
      child: Semantics(
        button: true,
        expanded: expansions.expanded,
        label: expansions.label,
        child: BgeFocusRing(
          borderRadius: BorderRadius.circular(tokens.radiusMd + ringReach),
          suppressed: pointerFocus,
          builder: (context, onFocusChange) => Padding(
            padding: EdgeInsets.all(ringReach),
            // No shape on the Material, which would cut the target's corners
            // off: the fill is ink, under the ink's own effects.
            child: Material(
              type: MaterialType.transparency,
              child: Ink(
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: radius,
                ),
                child: InkWell(
                  focusNode: focusNode,
                  onTapDown: (details) => notePointerPress(details.kind),
                  onTap: () {
                    focusNode.requestFocus();
                    expansions.onToggle();
                  },
                  onFocusChange: onFocusChange,
                  // The theme's tint, with no strength while the focus is a
                  // pointer's.
                  focusColor: pointerFocusColor,
                  borderRadius: radius,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: tokens.minTapTarget,
                      minHeight: tokens.minTapTarget,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: tokens.spaceSm,
                        vertical: tokens.spaceXs,
                      ),
                      child: ExcludeSemantics(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: tokens.spaceXs,
                          children: [
                            Icon(
                              Icons.extension,
                              size: tokens.spaceMd,
                              color: scheme.onTertiaryContainer,
                            ),
                            Text(
                              '${expansions.count}',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.onTertiaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
