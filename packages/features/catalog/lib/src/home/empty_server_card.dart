import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

/// What the home page says in the place of "Recently added" when the server
/// has no games (#617), to someone who can connect a DataGateway: a card with
/// the way to do it.
///
/// The message is a live region, as the loading and failed states it takes the
/// place of are, so that it is announced when it appears. The button is not
/// part of it, or the announcement would read the button out as well. Nothing
/// here holds focus except the button, which isn't there to lose when the
/// plain [EmptyServerMessage] gives way to this card.
class EmptyServerCard extends StatelessWidget {
  const EmptyServerCard({
    required this.onConnect,
    required this.messageKey,
    required this.actionKey,
    super.key,
  });

  /// Opens the list of DataGateways.
  final VoidCallback onConnect;

  /// Key on the message's text.
  final Key messageKey;

  /// Key on the button.
  final Key actionKey;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    return Card(
      // In line with the other sections.
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(tokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                l10n.catalogEmptyServerAdmin,
                key: messageKey,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const BgeGap.md(),
            FilledButton(
              key: actionKey,
              onPressed: onConnect,
              child: Text(l10n.catalogEmptyServerAdminAction),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the home page says in the place of "Recently added" when the server
/// has no games (#617), to everyone else, and to anyone whose access is not yet
/// known: centered text, with nothing to press.
///
/// A live region, so that it is announced when it appears.
class EmptyServerMessage extends StatelessWidget {
  const EmptyServerMessage({required this.messageKey, super.key});

  /// Key on the message's text.
  final Key messageKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceLg),
    child: Center(
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Text(
          GameCatalogLocalizations.of(context).catalogEmptyServer,
          key: messageKey,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    ),
  );
}
