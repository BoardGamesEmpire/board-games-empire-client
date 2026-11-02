import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

/// The spinner that stands in for a home page row while its first read runs.
///
/// [live] says whether it is announced when it appears. Sections offered
/// together would otherwise all say the same thing at once, so one of them
/// speaks for the rest. A quiet spinner can still be read by moving to it.
class ShelfLoading extends StatelessWidget {
  const ShelfLoading({required this.live, super.key});

  final bool live;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceLg),
    child: Center(
      child: Semantics(
        liveRegion: live,
        label: GameCatalogLocalizations.of(context).catalogBrowseLoading,
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}
