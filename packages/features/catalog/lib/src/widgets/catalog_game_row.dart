import 'package:flutter/material.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One game in a list (#42): the thumbnail, the title line and the facts
/// line, as one semantics node.
///
/// The collection row's shape (#44). Without [onTap] a row is inert content,
/// not a focus stop: a tap that leads nowhere is worse than no tap (#269).
class CatalogGameRow extends StatelessWidget {
  const CatalogGameRow({
    required this.title,
    this.thumbnailUrl,
    this.facts = const [],
    this.onTap,
    this.onlineOnly = false,
    this.nested = false,
    this.spokenTitle,
    this.note,
    super.key,
  });

  /// Key on every thumbnail placeholder.
  static const Key thumbnailPlaceholderKey = Key(
    'catalog.thumbnail_placeholder',
  );

  final String title;
  final String? thumbnailUrl;
  final List<CatalogFact> facts;
  final VoidCallback? onTap;

  /// Whether a tap is a write to the server (#49), such as an import. Offline
  /// the row is disabled and says why, in its own label.
  final bool onlineOnly;

  /// Whether the row is an expansion under its base game's row (#711): its
  /// start is indented beyond the tile's own padding.
  final bool nested;

  /// What a screen reader says for the title, when it differs from the
  /// words drawn.
  final String? spokenTitle;

  /// A line above the facts, shown and spoken.
  final String? note;

  @override
  Widget build(BuildContext context) {
    // MergeSemantics rather than a Semantics container: a tappable ListTile
    // builds an InkWell with its own node, and merging keeps the tap action
    // and the words on one node (the collection row's reasoning).
    final tokens = BgeTokens.of(context);
    final tile = MergeSemantics(
      child: ListTile(
        onTap: onTap,
        enabled: !(onlineOnly && BgeConnectivityScope.offlineOf(context)),
        leading: BgeThumbnail(
          url: thumbnailUrl,
          placeholderIcon: Icons.casino_outlined,
          placeholderKey: thumbnailPlaceholderKey,
        ),
        // The reason is a line of the title, so it stays in the row's one
        // node, ahead of the facts.
        title: onlineOnly
            ? BgeOnlineOnlyLabel(title, semanticsLabel: spokenTitle)
            : Text(title, semanticsLabel: spokenTitle),
        subtitle: note == null && facts.isEmpty
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (note != null) Text(note!),
                  if (facts.isNotEmpty) CatalogFactsText(facts),
                ],
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
