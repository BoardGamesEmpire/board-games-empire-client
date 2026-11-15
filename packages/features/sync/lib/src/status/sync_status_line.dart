import 'package:flutter/material.dart';
import 'package:sync_queue/l10n/sync_localizations.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Says where the session's changes stand, for the navigation drawer (#47):
/// all synced, how many are waiting, and how many couldn't sync, with a way
/// to review those.
///
/// Reads `BgeSyncStatusScope.countsOf`, and says only what has been read.
/// Each count stands on its own: the stuck line shows once the stuck changes
/// are read, whatever the pending count is doing, and the waiting line once
/// the pending count is. All synced needs both read as zero, so with no
/// session queue above it, before the queue has been read, or while a read
/// fails, it never claims that everything has synced.
///
/// Stuck comes first: it is the one that waits on the user. Each line is
/// an icon in its status colour and words, never colour alone, merged into
/// one semantics node. The words are in the drawer's text colour, not the
/// status colour (see `_Line`). None is a live region: the drawer is read
/// when the user opens it, and a count changing while it is open is not
/// news.
class SyncStatusLine extends StatelessWidget {
  const SyncStatusLine({required this.onReview, super.key});

  static const Key syncedKey = Key('sync_status_line.synced');
  static const Key waitingKey = Key('sync_status_line.waiting');
  static const Key stuckKey = Key('sync_status_line.stuck');
  static const Key reviewKey = Key('sync_status_line.review');

  /// Opens the screen where each stuck change can be retried or discarded.
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final (:waiting, :stuck) = BgeSyncStatusScope.countsOf(context);
    final anyStuck = stuck != null && stuck > 0;
    final anyWaiting = waiting != null && waiting > 0;
    final allSynced = stuck == 0 && waiting == 0;
    if (!anyStuck && !anyWaiting && !allSynced) return const SizedBox.shrink();
    final l10n = SyncLocalizations.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: BgeTokens.of(context).spaceXs,
      children: [
        if (anyStuck)
          _Line(
            key: stuckKey,
            status: BgeStatus.conflict,
            words: l10n.syncStatusStuck(stuck),
            action: TextButton(
              key: reviewKey,
              onPressed: onReview,
              child: Text(l10n.syncStatusReview),
            ),
          ),
        if (anyWaiting)
          _Line(
            key: waitingKey,
            status: BgeStatus.pending,
            words: l10n.syncStatusWaiting(waiting),
          ),
        if (allSynced)
          _Line(
            key: syncedKey,
            status: BgeStatus.synced,
            words: l10n.syncStatusAllSynced,
          ),
      ],
    );
  }
}

/// [status]'s icon in its colour, then [words], with an optional [action]
/// after them.
///
/// The words are in `onSurfaceVariant`, the drawer's own colour for its
/// destination labels and the one `BgeOfflineStrip` gives its message. The
/// status colours fall under 7:1 as text on the drawer's
/// `surfaceContainerLow` in both high-contrast schemes; as an icon, 3:1 is
/// enough. The words carry the meaning, the icon the colour and the shape.
class _Line extends StatelessWidget {
  const _Line({
    required this.status,
    required this.words,
    this.action,
    super.key,
  });

  final BgeStatus status;
  final String words;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;

    // The merge covers the icon and words only. The action stays out of it:
    // merged, a button stops being a control a screen reader can reach on
    // its own, as `BgeInlineBanner` keeps its action out of its node.
    final said = MergeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            BgeStatusColors.iconFor(status),
            // Sized as its words are, and scaled with them, as the row
            // badges' icons are.
            size: MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 0),
            color: BgeStatusColors.of(context).colorFor(status),
          ),
          const BgeGap.sm(axis: Axis.horizontal),
          // Flexible, so the words wrap within the drawer at large text.
          Flexible(
            child: Text(
              words,
              style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );

    final action = this.action;
    if (action == null) return said;
    // The action sits after the words while both fit on one line, and goes
    // under them otherwise. Both arrangements place the same two children,
    // so the button keeps its element, and its focus, across the change.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: BgeTokens.of(context).spaceSm,
      children: [said, action],
    );
  }
}
