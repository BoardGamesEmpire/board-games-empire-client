import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Marks a cover that stands for several entries (#709): two cards offset
/// behind it, toward the top and the end, and a badge with how many.
///
/// The marker is its child plus two offsets of [BgeTokens.spaceXs] each way
/// ([reachOf]), so the cards never reach outside the box the marker is laid
/// out in. The
/// child is placed at the bottom and the start of it. In a right-to-left
/// language the cards and the badge are on the left.
///
/// The badge shows the number alone, in the secondary colours: the error
/// colours are for failures, and no glyph keeps it apart from other badges.
/// It adds nothing to the semantics tree, as the host's own label carries the
/// count.
class BgeStackMarker extends StatelessWidget {
  const BgeStackMarker({required this.count, required this.child, super.key});

  /// Finds the badge.
  static const Key badgeKey = Key('bge_stack_marker.badge');

  /// How far the marker reaches beyond its child, toward the top and the
  /// end: a step of [BgeTokens.spaceXs] for each of the two cards.
  ///
  /// A host that has a size for the whole marker gives the child that size
  /// less this, so the marked whole lines up with unmarked neighbours.
  static double reachOf(BuildContext context) =>
      2 * BgeTokens.of(context).spaceXs;

  /// How many entries the child stands for.
  final int count;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final step = tokens.spaceXs;
    final reach = reachOf(context);

    Widget layer(double inset) => Positioned.directional(
      textDirection: Directionality.of(context),
      top: reach - inset,
      end: reach - inset,
      bottom: inset,
      start: inset,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(tokens.radiusSm),
        ),
      ),
    );

    return Stack(
      children: [
        // Farthest first, each a further step toward the top and the end than
        // the child, whose own rect is where an offset of zero would be.
        layer(reach),
        layer(step),
        Padding(
          padding: EdgeInsetsDirectional.only(top: reach, end: reach),
          child: child,
        ),
        // Scaled down to the marker's width when a long count at a large text
        // size would not fit, so it never reaches outside the box.
        Positioned.fill(
          child: FittedBox(
            alignment: AlignmentDirectional.topEnd,
            fit: BoxFit.scaleDown,
            child: ExcludeSemantics(
              child: Badge(
                key: badgeKey,
                backgroundColor: scheme.secondary,
                textColor: scheme.onSecondary,
                label: Text('$count'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
