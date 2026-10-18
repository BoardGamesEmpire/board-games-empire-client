import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

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

/// The spinner a screen shows before its first answer, announced once.
class CatalogLoadingSliver extends StatelessWidget {
  const CatalogLoadingSliver({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Semantics(
        liveRegion: true,
        label: message,
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}

/// A short message filling the rest of the page.
class CatalogMessageSliver extends StatelessWidget {
  const CatalogMessageSliver({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SliverFillRemaining(hasScrollBody: false, child: Center(child: child));
}

/// The banner over what a screen shows from this device's cache because
/// the server's answer failed, with a retry that asks the server again.
///
/// Furniture for as long as the screen shows the cache, so it does not
/// scroll itself into view.
///
/// A screen that keeps the cache up while it retries passes [retrying]: the
/// button keeps its place, disabled and relabelled, and the new label is
/// announced, as the browse list's "more" button does.
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
    return BgeInlineBanner(
      tone: BgeBannerTone.warning,
      message: message,
      reveal: false,
      action: Semantics(
        liveRegion: retrying,
        child: TextButton(
          onPressed: retrying ? null : onRetry,
          child: Text(retrying ? l10n.catalogRetrying : l10n.catalogRetry),
        ),
      ),
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
