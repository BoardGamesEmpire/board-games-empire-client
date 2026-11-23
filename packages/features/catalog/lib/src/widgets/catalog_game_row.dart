import 'package:flutter/material.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_filters/game_filters.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One game in a list (#42): the thumbnail, the title line and the facts
/// line, as one semantics node.
///
/// Outlined as a [BgeOutlinedRow] (#647), each game its own bordered row with
/// a gap below it.
///
/// The collection row's shape (#44). Without [onTap] a row is inert content,
/// not a focus stop: a tap that leads nowhere is worse than no tap (#269).
///
/// A base game's row in a list that folds its expansions carries
/// [expansions]: the 🧩 control at the row's end, a button and a focus stop
/// of its own after the row's, and the row's Show/Hide expansions custom
/// action (#1048).
class CatalogGameRow extends StatelessWidget {
  const CatalogGameRow({
    required this.title,
    this.thumbnailUrl,
    this.facts = const [],
    this.onTap,
    this.nested = false,
    this.spokenTitle,
    this.note,
    this.summary,
    this.expansions,
    super.key,
  });

  /// Key on every thumbnail placeholder.
  static const Key thumbnailPlaceholderKey = Key(
    'catalog.thumbnail_placeholder',
  );

  final String title;
  final String? thumbnailUrl;
  final List<GameFact> facts;
  final VoidCallback? onTap;

  /// Whether the row is an expansion under its base game's row (#711): its
  /// start is indented beyond the tile's own padding.
  final bool nested;

  /// What a screen reader says for the title, when it differs from the
  /// words drawn.
  final String? spokenTitle;

  /// A line above the facts, shown and spoken.
  final String? note;

  /// A line under the facts (#558): a DataGateway result's summary as plain
  /// text, cut to one line. Spoken after the facts, in the row's one node.
  final String? summary;

  /// The game's expansions, which the control at the row's end counts, and
  /// shows and hides under the row (#1048). Null for no control: a game with
  /// none, or a list that doesn't fold them.
  final BgeCoverExpansions? expansions;

  @override
  Widget build(BuildContext context) {
    // BgeExpansionsRow merges the tile's semantics, rather than a Semantics
    // container: a tappable ListTile builds an InkWell with its own node, and
    // merging keeps the tap action and the words on one node (the collection
    // row's reasoning). It sits inside the outline, so the node's rect
    // leaves out the gap below the row (#647). It places the expansions
    // control beside the tile, outside that node, and is there with
    // [expansions] or without, so the tile keeps its element and its focus
    // as a base game's first expansion arrives or its last goes (#1048).
    final tokens = BgeTokens.of(context);
    final tile = BgeOutlinedRow(
      child: BgeExpansionsRow(
        expansions: expansions,
        builder: (context, focusNode) => BgeRowFocusRing(
          focusNode: focusNode,
          builder: (context, row) => ListTile(
            titleAlignment: BgeThumbnail.titleAlignmentOf(context),
            minTileHeight: BgeThumbnail.minTileHeightOf(context),
            focusNode: row.focusNode,
            onFocusChange: row.onFocusChange,
            focusColor: row.focusColor,
            onTap: row.onTap(onTap),
            leading: BgeThumbnail(
              url: thumbnailUrl,
              placeholderIcon: Icons.casino_outlined,
              placeholderKey: thumbnailPlaceholderKey,
            ),
            title: Text(title, semanticsLabel: spokenTitle),
            subtitle: note == null && facts.isEmpty && summary == null
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (note != null) Text(note!),
                      if (facts.isNotEmpty) CatalogFactsText(facts),
                      if (summary != null)
                        Text(
                          summary!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
    if (!nested) return tile;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: tokens.spaceLg),
      child: tile,
    );
  }
}
