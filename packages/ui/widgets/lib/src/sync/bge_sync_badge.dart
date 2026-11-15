import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Where a record's change stands on its way to the server (#47).
///
/// A record that has reached the server has no state: it shows nothing.
enum BgeSyncState {
  /// A change is queued and the server hasn't had it yet. It will send on
  /// its own once the server can be reached.
  waiting,

  /// A change the server refused, or that ran out of attempts. It will not
  /// send on its own: the user retries or discards it from the stuck-changes
  /// screen.
  stuck,
}

/// A record's sync state as an icon plus words, for a list row (#47).
///
/// The household list's private "Not yet synced" badge, generalised to
/// every row the sync queue owns. Waiting is [BgeStatus.pending]'s colour
/// and icon, stuck is [BgeStatus.conflict]'s: never colour alone, which is
/// the project's standing answer to colour-vision deficiency.
///
/// [label] is drawn text with no semantics node of its own, so a row that
/// merges its semantics reads it with the row's title. Put it under the
/// row's details rather than in a `ListTile.trailing`, which has no room
/// for it at 200% text.
class BgeSyncBadge extends StatelessWidget {
  const BgeSyncBadge({required this.state, required this.label, super.key});

  final BgeSyncState state;

  /// Localized words for [state], such as "Not yet synced".
  final String label;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Sized as the label's text is: an icon pinned to a fixed size
        // beside 200%-scaled text stops reading as part of the same badge.
        _SyncIcon(state: state, size: style?.fontSize ?? 0),
        const BgeGap.xs(axis: Axis.horizontal),
        // Flexible, so the label wraps inside the row rather than
        // overflowing it on a narrow window.
        Flexible(
          child: Text(
            label,
            style: style?.copyWith(color: _colorOf(context, state)),
          ),
        ),
      ],
    );
  }
}

/// A record's sync state as an icon alone, for a cover (#47).
///
/// A cover has no room for [BgeSyncBadge]'s words, so this is the badge's
/// icon in its status colour, on a disc of [BgeStatusColors.onStatus] that
/// keeps it legible over any picture. It adds nothing to the semantics tree:
/// the cover's own label carries the words, as it carries a stack's count.
///
/// The glyph is the only cue a sighted user gets, so it is drawn at the size
/// of the cover's other glyphs, [BgeTokens.spaceMd], the expansions badge's
/// and the missing-part tab's: large enough for waiting's cloud and stuck's
/// error mark to be told apart by shape, not only by colour. It scales with
/// the text; the cover caps the whole mark, and scales it down to fit.
class BgeSyncMark extends StatelessWidget {
  const BgeSyncMark({required this.state, super.key});

  final BgeSyncState state;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: BgeStatusColors.of(context).onStatus,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: EdgeInsets.all(tokens.spaceXs),
          child: _SyncIcon(state: state, size: tokens.spaceMd),
        ),
      ),
    );
  }
}

/// The icon paired with [state], in its status colour, at [size] scaled by
/// the text scaler.
class _SyncIcon extends StatelessWidget {
  const _SyncIcon({required this.state, required this.size});

  final BgeSyncState state;

  /// The size at a text scale of 1.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Icon(
      BgeStatusColors.iconFor(_statusOf(state)),
      size: MediaQuery.textScalerOf(context).scale(size),
      color: _colorOf(context, state),
    );
  }
}

BgeStatus _statusOf(BgeSyncState state) => switch (state) {
  BgeSyncState.waiting => BgeStatus.pending,
  BgeSyncState.stuck => BgeStatus.conflict,
};

Color _colorOf(BuildContext context, BgeSyncState state) =>
    BgeStatusColors.of(context).colorFor(_statusOf(state));
