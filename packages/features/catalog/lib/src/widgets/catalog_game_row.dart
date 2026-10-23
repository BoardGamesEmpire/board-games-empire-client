import 'package:flutter/material.dart';
import 'package:ui/ui.dart';

import 'catalog_facts.dart';

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

  @override
  Widget build(BuildContext context) {
    // MergeSemantics rather than a Semantics container: a tappable ListTile
    // builds an InkWell with its own node, and merging keeps the tap action
    // and the words on one node (the collection row's reasoning).
    return MergeSemantics(
      child: ListTile(
        onTap: onTap,
        leading: BgeThumbnail(
          url: thumbnailUrl,
          placeholderIcon: Icons.casino_outlined,
          placeholderKey: thumbnailPlaceholderKey,
        ),
        title: Text(title),
        subtitle: facts.isEmpty ? null : CatalogFactsText(facts),
      ),
    );
  }
}
