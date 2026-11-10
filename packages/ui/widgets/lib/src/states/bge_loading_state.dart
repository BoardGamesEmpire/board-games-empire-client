import 'package:flutter/material.dart';

/// A spinner for content on its way, which a screen reader announces as
/// [label] when it appears (#49).
///
/// ```dart
/// BgeLoadingState(label: l10n.eventsLoading)
/// ```
///
/// Spinner only, no skeletons. Content, not a page: the caller supplies the
/// page, or a `BgeStateSliver` on a sliver one. Pairs with `BgeErrorState` and
/// `BgeEmptyState`.
///
/// ## Accessibility
///
/// - **The label is one live region.** Assistive tech reads it once, when the
///   spinner appears, without focus having to land on it.
/// - **The spinner says nothing.** It is excluded from semantics, so the label
///   is not followed by an unlabelled progress indicator.
class BgeLoadingState extends StatelessWidget {
  /// Creates a loading state.
  const BgeLoadingState({required this.label, super.key});

  /// What is loading. Announced, never drawn. Already localized.
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: label,
    child: const ExcludeSemantics(child: CircularProgressIndicator()),
  );
}
