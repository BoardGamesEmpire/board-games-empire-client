import 'package:flutter/material.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A section heading in a list, announced as a heading.
class CatalogSectionHeading extends StatelessWidget {
  const CatalogSectionHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(top: tokens.spaceMd, bottom: tokens.spaceSm),
      child: Semantics(
        header: true,
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      ),
    );
  }
}

/// The banner over what a screen shows from this device's cache because
/// the server's answer failed, with a retry that asks the server again.
///
/// The catalog's [BgeRefreshBanner]: furniture for as long as the screen
/// shows the cache, so it does not scroll itself into view. The quick look
/// (#707) puts it over what the list already knew, too, when there is no
/// cached copy to show.
///
/// A screen that keeps the cache up while it retries passes [retrying]: the
/// banner says so, and the retry keeps its place and its focus, relabelled
/// and inert until the answer comes (#607).
class CatalogFromCacheBanner extends StatelessWidget {
  const CatalogFromCacheBanner({
    required this.message,
    required this.onRetry,
    this.retrying = false,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    return BgeRefreshBanner(
      failedMessage: message,
      inProgressLabel: l10n.catalogRetrying,
      retryLabel: l10n.catalogRetry,
      retryKey: const ValueKey('catalogFromCacheRetry'),
      refreshing: retrying,
      onRetry: onRetry,
    );
  }
}

/// What a screen shows when the server's answer failed and there was
/// nothing on this device to show instead, or when the server refused.
class CatalogErrorState extends StatelessWidget {
  const CatalogErrorState({
    required this.title,
    required this.body,
    required this.onRetry,
    this.icon = Icons.cloud_off_outlined,
    super.key,
  });

  final String title;
  final String body;
  final VoidCallback onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) => BgeErrorState(
    icon: icon,
    title: title,
    body: body,
    retryLabel: GameCatalogLocalizations.of(context).catalogRetry,
    onRetry: onRetry,
  );
}
