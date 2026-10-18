import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_detail_bloc.dart';
import '../bloc/game_detail_event.dart';
import '../bloc/game_detail_state.dart';
import '../widgets/catalog_facts.dart';
import '../widgets/catalog_slivers.dart';
import '../widgets/game_description.dart';

/// One game (#42): its facts, its description as Markdown (#472), and the
/// platforms it is available on.
///
/// ## Adding to the collection is a callback
///
/// Picking a platform calls [onAdd] with that platform game, which #45
/// supplies. Null, there is no add button, as the household list offers no
/// create without a way to send one (#269). The list is empty until the
/// server sends platform games (backend#791).
///
/// ## Links
///
/// A link in the description opens through [openLink], outside the app. The
/// default is the platform's browser or mail client (`url_launcher`); tests
/// pass their own.
class GameDetailScreen extends StatelessWidget {
  const GameDetailScreen({
    required this.gameId,
    required this.remote,
    this.cache,
    this.onAdd,
    this.openLink = openLinkExternally,
    super.key,
  });

  static const Key loadingKey = Key('catalog_detail.loading');
  static const Key unavailableKey = Key('catalog_detail.unavailable');
  static const Key errorKey = Key('catalog_detail.error');
  static const Key fromCacheBannerKey = Key('catalog_detail.from_cache');
  static const Key factsKey = Key('catalog_detail.facts');
  static const Key descriptionKey = Key('catalog_detail.description');

  /// Per-platform key: `catalog_detail.platform_<platformGameId>`.
  static Key platformKey(String platformGameId) =>
      Key('catalog_detail.platform_$platformGameId');

  /// The add button for one platform game.
  static Key addKey(String platformGameId) =>
      Key('catalog_detail.add_$platformGameId');

  static final BgeLogger _log = BgeLogger('bge.catalog.detail.link');

  /// Opens [uri] in the platform's own app for it: the browser for a web
  /// link, the mail client for `mailto`. A failure is logged, not shown:
  /// the link stays on screen to copy.
  static Future<void> openLinkExternally(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) _log.info('No app opened a description link');
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Opening a description link failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// The game's id, from the route, unvalidated. An id that cannot name a
  /// game shows the unavailable state.
  final String gameId;
  final GamesRemoteDataSource remote;

  /// The user-session games cache, or null where there is none.
  final GameRepository? cache;

  /// Adds the game on one platform to the collection (#45). Null offers no
  /// add.
  final void Function(BuildContext context, PlatformGameSummary platformGame)?
  onAdd;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) => BlocProvider<GameDetailBloc>(
    // Keyed on the game, as the DataGateway form is on its row: go_router
    // keys a page by its path pattern, so going from one game straight to
    // another rebuilds this screen in place, and a new id needs a new bloc.
    key: ValueKey<String>(gameId),
    create: (_) =>
        GameDetailBloc(gameId: gameId, remote: remote, cache: cache)
          ..add(const GameDetailLoadRequested()),
    child: _GameDetailPage(onAdd: onAdd, openLink: openLink),
  );
}

class _GameDetailPage extends StatelessWidget {
  const _GameDetailPage({required this.openLink, this.onAdd});

  final void Function(BuildContext context, PlatformGameSummary platformGame)?
  onAdd;
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);

    return BlocBuilder<GameDetailBloc, GameDetailState>(
      builder: (context, state) {
        void retry() =>
            context.read<GameDetailBloc>().add(const GameDetailLoadRequested());

        return switch (state) {
          GameDetailLoading() => BgePage(
            title: Text(l10n.catalogDetailTitle),
            centerVertically: true,
            child: Center(
              key: GameDetailScreen.loadingKey,
              child: Semantics(
                liveRegion: true,
                label: l10n.catalogDetailLoading,
                child: const ExcludeSemantics(
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          ),
          GameDetailUnavailable() => BgePage(
            title: Text(l10n.catalogDetailTitle),
            centerVertically: true,
            child: Column(
              key: GameDetailScreen.unavailableKey,
              children: [
                Text(
                  l10n.catalogDetailUnavailableTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const BgeGap.sm(),
                Text(
                  l10n.catalogDetailUnavailableBody,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          GameDetailFailed() => BgePage(
            title: Text(l10n.catalogDetailTitle),
            centerVertically: true,
            child: CatalogErrorState(
              key: GameDetailScreen.errorKey,
              title: l10n.catalogDetailFailedTitle,
              body: l10n.catalogDetailFailedBody,
              onRetry: retry,
            ),
          ),
          GameDetailReady(
            :final game,
            :final platformGames,
            :final fromCache,
          ) =>
            // The reading measure: the description is prose, and a surface
            // mixing prose with rows takes the prose's width (STYLE_GUIDE).
            BgePage(
              title: Text(game.title),
              child: _GameDetailBody(
                game: game,
                platformGames: platformGames,
                fromCache: fromCache,
                onRetry: retry,
                onAdd: onAdd,
                openLink: openLink,
              ),
            ),
        };
      },
    );
  }
}

class _GameDetailBody extends StatelessWidget {
  const _GameDetailBody({
    required this.game,
    required this.platformGames,
    required this.fromCache,
    required this.onRetry,
    required this.openLink,
    this.onAdd,
  });

  /// The largest the game's image may be drawn.
  static const double _imageExtent = 160;

  final Game game;
  final List<PlatformGameSummary> platformGames;
  final bool fromCache;
  final VoidCallback onRetry;
  final void Function(BuildContext context, PlatformGameSummary platformGame)?
  onAdd;
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final theme = Theme.of(context);
    final facts = _facts(l10n);
    final subtitle = game.subtitle;
    final description = game.description;
    final add = onAdd;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fromCache) ...[
          CatalogFromCacheBanner(
            key: GameDetailScreen.fromCacheBannerKey,
            message: l10n.catalogDetailFromCache,
            onRetry: onRetry,
          ),
          const BgeGap.md(),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BgeThumbnail(
              url: game.image ?? game.thumbnail,
              extent: _imageExtent,
              placeholderIcon: Icons.casino_outlined,
            ),
            const BgeGap.md(axis: Axis.horizontal),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      game.title,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Text(subtitle, style: theme.textTheme.titleMedium),
                  if (facts.isNotEmpty) ...[
                    const BgeGap.sm(),
                    CatalogFactsText(facts, key: GameDetailScreen.factsKey),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (platformGames.isNotEmpty) ...[
          CatalogSectionHeading(l10n.catalogDetailAvailableOn),
          for (final platformGame in platformGames)
            MergeSemantics(
              key: GameDetailScreen.platformKey(platformGame.id),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(platformGame.platformName),
                trailing: add == null
                    ? null
                    : TextButton(
                        key: GameDetailScreen.addKey(platformGame.id),
                        onPressed: () => add(context, platformGame),
                        child: Text(l10n.catalogDetailAddToCollection),
                      ),
              ),
            ),
        ],
        if (description != null && description.trim().isNotEmpty) ...[
          CatalogSectionHeading(l10n.catalogDetailDescription),
          GameDescription(
            key: GameDetailScreen.descriptionKey,
            markdown: description,
            onOpenLink: openLink,
          ),
        ],
      ],
    );
  }

  List<CatalogFact> _facts(GameCatalogLocalizations l10n) {
    final year = game.publishYear;
    final age = game.minAge;
    final type = contentTypeLabel(l10n, game.contentType);
    return [
      if (type != null) sameFact(type),
      if (year != null) sameFact(l10n.catalogDetailPublished('$year')),
      ?playersFact(l10n, game.minPlayers, game.maxPlayers),
      ?playTimeFact(l10n, game),
      if (age != null)
        (
          shown: l10n.catalogDetailMinAge('$age'),
          spoken: l10n.catalogDetailMinAgeSpoken('$age'),
        ),
    ];
  }
}
