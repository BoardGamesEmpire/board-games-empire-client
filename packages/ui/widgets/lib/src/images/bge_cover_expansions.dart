import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSliver;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
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

/// The badge `BgeCoverTile` draws for its [BgeCoverExpansions] (#711), and
/// `BgeRowExpansionsControl` at a list row's end (#1048).
///
/// Not exported: the tile places it, at the bottom end of the picture, and
/// the row control places it beside the row's tile. One look in both.
///
/// A quiet button, in the `surfaceContainerHighest` colour with an `outline`
/// border and its content in `onSurface`, with a puzzle piece and the count.
/// Ember, the tertiary colour, is left to the cover's missing-base mark: most
/// base games with expansions carry this badge, and §1 of the style guide
/// keeps ember rare (#817). It is unlike `BgeStackMarker`'s badge on purpose,
/// which sits at the top end, in the secondary colours, with a number alone:
/// the two can be on one cover, and they count different things.
///
/// ## Size
///
/// At least [BgeTokens.minTapTarget] square, and drawn as big as it takes
/// presses. A smaller badge with a larger, invisible target would take
/// presses aimed at the cover beside it. The whole of its box takes them,
/// rounded corners included: the fill is painted as ink on a `Material` with
/// no shape, because a shaped one hit-tests against its shape and would send
/// a press near a corner to the cover underneath, opening the game. The
/// border is drawn over the fill, inside the same box, so it adds no size
/// and takes presses as the rest of the badge does. The count grows with the
/// text, and the icon, which the count and the name already say, doesn't, so
/// that a two-digit count still leaves most of a phone's cover.
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
/// [focusNode] is its owner's, the tile's or the row's, so that the owner
/// can hand focus on when the badge goes while it holds it.
///
/// The ring is the two tones drawn over a picture ([BgeFocusRing.overPicture])
/// on a cover, and the single tone every control on a plain surface has
/// where [overPicture] is false, as on a row.
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
    this.overPicture = true,
    super.key,
  });

  /// What the badge counts and toggles.
  final BgeCoverExpansions expansions;

  /// The badge's focus, which its owner disposes.
  final FocusNode focusNode;

  /// Whether the badge sits over a picture, which draws its focus ring in
  /// two tones. True on a cover.
  final bool overPicture;

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
          overPicture: widget.overPicture,
          builder: (context, onFocusChange) => Padding(
            padding: EdgeInsets.all(ringReach),
            // No shape on the Material, which would cut the target's corners
            // off: the fill is ink, under the ink's own effects.
            child: Material(
              type: MaterialType.transparency,
              child: Ink(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: radius,
                ),
                // The border is drawn over the fill, inside the target, so it
                // takes presses with the rest of the badge.
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.outline),
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
                                color: scheme.onSurface,
                              ),
                              Text(
                                '${expansions.count}',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: scheme.onSurface,
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
      ),
    );
  }
}

/// Hands the focus on from [leaving], an expansions badge whose expansions
/// went in this frame while it held the focus, where nothing beside it can
/// take it: as an inert row's tile or cover can't (#1048). Then calls
/// [then], which takes the badge away.
///
/// The focus goes where Tab would take it from the badge: to the next stop
/// after it, and with none, to the one before it, as Shift+Tab would.
/// Brought into view as a Tab's is, so it is never parked out of sight.
/// Never to the page: left alone, the framework would give the focus back
/// to the control focused before the badge, or with none, to the page
/// itself.
///
/// The badge's owner keeps building it for the rest of this frame, and both
/// stops are found at the frame's end, once the page is laid out. Tab's
/// order is worked out from where each stop is drawn, which a stop built in
/// this frame, as a sync can build a new row above the game's, has not been
/// given yet. Found then, the order is the page's as it now stands: a sync
/// that takes the next game's row with this game's last expansion leaves
/// the stop before to take the focus. The request lands before the frame
/// that takes the badge away, so the badge never goes with the focus.
///
/// Focus that has left the badge by the end of the frame stays where it
/// is. A request made elsewhere in the same frame that has not landed yet
/// can't be told apart, so this one, made after it, takes its place.
///
/// [owner] is the stop of the badge's owner, its cover or its row's tile,
/// which takes the focus instead where it can by the frame's end. It is
/// asked then, not as the badge goes: an owner given something to open in
/// the same update its badge goes in is built again after that, and its
/// node takes focus only from that build on.
void handFocusOnFromBadge(
  FocusNode leaving, {
  required FocusNode owner,
  required VoidCallback then,
}) {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    // A node keeps its context once it leaves the tree, so whether its
    // element is still mounted is what tells.
    if (leaving.context?.mounted == true && leaving.hasPrimaryFocus) {
      if (owner.context?.mounted == true && owner.canRequestFocus) {
        owner.requestFocus();
      } else if (_scopeIsLaidOut(leaving)) {
        _handOnAsTab(leaving);
      }
    }
    then();
  });
}

/// Moves the focus from [leaving] to the stop Tab would take it to, else to
/// the one Shift+Tab would, brought into view as theirs are.
void _handOnAsTab(FocusNode leaving) {
  final next = _stopBeside(leaving, forward: true);
  final stop = next ?? _stopBeside(leaving, forward: false);
  if (stop == null) return;
  FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
    stop,
    alignmentPolicy: next != null
        ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
        : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
  );
}

/// Whether every node in [node]'s scope has been laid out, which sorting
/// the scope into Tab's order needs: it reads where each is drawn, and one
/// with no size yet throws. At a frame's end each one built is laid out;
/// this keeps a stop that some layout skipped from throwing, and leaves the
/// focus to the framework then.
bool _scopeIsLaidOut(FocusNode node) {
  final scope = node.nearestScope;
  if (scope == null) return false;
  return scope.descendants.every(
    (descendant) => switch (descendant.context?.findRenderObject()) {
      null => false,
      RenderBox(:final hasSize) => hasSize,
      RenderSliver(:final geometry) => geometry != null,
      _ => true,
    },
  );
}

/// The stop Tab, or Shift+Tab where not [forward], would move the focus to
/// from [from], which has it, in the order the page's traversal groups set.
/// Null at either end of the page's stops, where Tab would leave the page or
/// go round to its other end.
FocusNode? _stopBeside(FocusNode from, {required bool forward}) {
  // Asked of a policy that only notes where it would go: the order is the
  // traversal groups' own, whatever policy asks.
  FocusNode? found;
  final noting = ReadingOrderTraversalPolicy(
    requestFocusCallback: (
      node, {
      alignment,
      alignmentPolicy,
      curve,
      duration,
    }) => found = node,
  );
  final end = forward
      ? noting.findLastFocus(from, ignoreCurrentFocus: true)
      : noting.findFirstFocus(from, ignoreCurrentFocus: true);
  if (end == null || identical(end, from)) return null;
  if (forward) {
    noting.next(from);
  } else {
    noting.previous(from);
  }
  return found;
}
