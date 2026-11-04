import 'package:flutter/material.dart';

/// Fills the rest of a sliver page and centres [child] in it: the wrapper for a
/// `BgeLoadingState`, `BgeEmptyState` or `BgeErrorState` that stands in for a
/// list (#49).
///
/// `hasScrollBody: false`, so a state taller than what is left, such as at 200%
/// text scale, scrolls with the page instead of overflowing it.
class BgeStateSliver extends StatelessWidget {
  /// Creates a sliver that centres [child] in the remaining space.
  const BgeStateSliver({required this.child, super.key});

  /// The state to show.
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SliverFillRemaining(hasScrollBody: false, child: Center(child: child));
}
