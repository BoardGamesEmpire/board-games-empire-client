import 'package:flutter/material.dart';

import 'bge_connectivity_scope.dart';

/// The reason line shared by [BgeOnlineOnly] and [BgeOnlineOnlyLabel]:
/// `bodySmall` in `onSurfaceVariant`, which the scheme tests cover on every
/// surface role.
TextStyle? _reasonStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodySmall?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  );
}

/// Wraps a direct-write control so that offline, its disabled state says why
/// (#49).
///
/// The control sits in a `MergeSemantics(Semantics(hint: reason))`, so
/// offline a screen reader meets one node: the control's own label and state,
/// with the reason as its hint. Online the hint is null and the node reads as
/// the control's own. With [showNote] the reason is also drawn below it while
/// offline, excluded from semantics so it is not read twice.
///
/// The tree has one shape online and offline, so the control keeps its
/// element, its state and its semantics node when the connection comes and
/// goes: a busy submit's live progress label is not announced again, and a
/// button keeps its ink and focus.
///
/// The caller still sets `onPressed: null` (or `onSelected: null`) from
/// `BgeConnectivityScope.offlineOf`; this widget only explains.
///
/// Do not wrap a group of controls in one: `MergeSemantics` would fold a row
/// of chips into a single node. Wrap each with `showNote: false`, and put one
/// [BgeOnlineOnlyNote] under the group.
class BgeOnlineOnly extends StatelessWidget {
  const BgeOnlineOnly({required this.child, this.showNote = true, super.key});

  final Widget child;

  /// Whether to draw the reason as a note below [child] while offline.
  final bool showNote;

  @override
  Widget build(BuildContext context) {
    final reason = BgeConnectivityScope.onlineOnlyReasonOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      // The note lines up with the control's start edge, not its middle.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MergeSemantics(
          // Offline the merged node says disabled itself, not only through
          // what it merges: Flutter's text-contrast guideline reads a node's
          // own flags, and would otherwise hold the control's dimmed label to
          // 4.5:1, which WCAG 1.4.3 exempts (#50). What a screen reader hears
          // doesn't change: the merged control already says disabled.
          child: Semantics(
            hint: reason,
            enabled: reason == null ? null : false,
            child: child,
          ),
        ),
        if (showNote && reason != null) const BgeOnlineOnlyNote(),
      ],
    );
  }
}

/// The reason line on its own: for one note under a group of controls, or
/// under a row of gated buttons, where wrapping the whole group in
/// [BgeOnlineOnly] would merge them into one semantics node.
///
/// Draws nothing while online. Excluded from semantics: each control carries
/// the reason as its hint.
class BgeOnlineOnlyNote extends StatelessWidget {
  const BgeOnlineOnlyNote({super.key});

  @override
  Widget build(BuildContext context) {
    final reason = BgeConnectivityScope.onlineOnlyReasonOf(context);
    if (reason == null) return const SizedBox.shrink();

    return ExcludeSemantics(child: Text(reason, style: _reasonStyle(context)));
  }
}

/// A menu-item or list-tile label: [label], plus the reason as a second line
/// while offline.
///
/// The enclosing item merges both lines into one label, so the reason is
/// read once, with the item. The reason takes the note's style so it stays
/// legible on a disabled item.
class BgeOnlineOnlyLabel extends StatelessWidget {
  const BgeOnlineOnlyLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final reason = BgeConnectivityScope.onlineOnlyReasonOf(context);
    if (reason == null) return Text(label);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Text(reason, style: _reasonStyle(context)),
      ],
    );
  }
}
