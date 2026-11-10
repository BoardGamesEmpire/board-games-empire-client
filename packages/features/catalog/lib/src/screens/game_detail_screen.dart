import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_detail_bloc.dart';
import 'package:game_catalog/src/bloc/game_detail_event.dart';
import 'package:game_catalog/src/bloc/game_detail_state.dart';
import 'package:game_catalog/src/screens/game_detail_collection.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_catalog/src/widgets/cover_beside_title.dart';
import 'package:game_catalog/src/widgets/game_description.dart';
import 'package:game_catalog/src/widgets/game_detail_platforms.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:url_launcher/url_launcher.dart';

/// One game (#42): its facts, its description as Markdown (#472), and the
/// platforms it is available on.
///
/// ## The collection comes as callbacks
///
/// Each platform is a chip that says whether the user owns the game there,
/// and one button under the chips adds it on another (#708): see
/// [GameDetailPlatforms]. What the user owns, the add and the opening of an
/// owned copy all come from [collection], which the shell supplies, so the
/// catalog needs nothing of the collection feature. Null, the chips are
/// plain labels and there is no add button, as the household list offers no
/// create without a way to send one (#269). An empty list of platforms means
/// the game is on none, or the caller may not read its platform games.
///
/// ## A game found gone
///
/// A game the server no longer has, or this user may no longer read, is
/// reported to [onGone] as soon as the server says so, so the lists already
/// open can take it down: the one it was opened from, and any beneath that.
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
    this.onGone,
    this.collection,
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

  /// The legend under the platforms that says what the check means.
  static const Key ownedLegendKey = Key('catalog_detail.owned_legend');

  /// The one add button, under the platforms.
  static const Key addKey = Key('catalog_detail.add');

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

  /// Told the game's id when it turns out to be gone. Null tells no one.
  final void Function(String gameId)? onGone;

  /// What the page can do with the user's collection (#708). Null offers no
  /// add and says nothing of ownership.
  final GameDetailCollection? collection;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) => BlocProvider<GameDetailBloc>(
    // Keyed on the game, as the DataGateway form is on its row: go_router
    // keys a page by its path pattern, so going from one game straight to
    // another rebuilds this screen in place, and a new id needs a new bloc.
    key: ValueKey<String>(gameId),
    create: (_) => GameDetailBloc(
      gameId: gameId,
      remote: remote,
      cache: cache,
      onGone: onGone,
    )..add(const GameDetailLoadRequested()),
    child: _GameDetailPage(collection: collection, openLink: openLink),
  );
}

class _GameDetailPage extends StatelessWidget {
  const _GameDetailPage({required this.openLink, this.collection});

  final GameDetailCollection? collection;
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
              child: BgeLoadingState(
                key: GameDetailScreen.loadingKey,
                label: l10n.catalogDetailLoading,
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
                collection: collection,
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
    this.collection,
  });

  /// The largest the game's image may be drawn.
  static const double _imageExtent = 160;

  final Game game;
  final List<PlatformGame> platformGames;
  final bool fromCache;
  final VoidCallback onRetry;
  final GameDetailCollection? collection;
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final theme = Theme.of(context);
    final facts = _facts(l10n, GameFiltersLocalizations.of(context));
    final subtitle = game.subtitle;
    final description = game.description;

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
        CoverBesideTitle(
          cover: BgeThumbnail(
            url: game.image ?? game.thumbnail,
            extent: _imageExtent,
            placeholderIcon: Icons.casino_outlined,
          ),
          coverExtent: _imageExtent,
          titleFontSize:
              theme.textTheme.headlineSmall?.fontSize ??
              BgeTypography.headlineSmall,
          titles: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(game.title, style: theme.textTheme.headlineSmall),
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
        if (platformGames.isNotEmpty) ...[
          CatalogSectionHeading(l10n.catalogDetailAvailableOn),
          GameDetailPlatforms(
            game: game,
            platformGames: platformGames,
            collection: collection,
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

  List<GameFact> _facts(
    GameCatalogLocalizations l10n,
    GameFiltersLocalizations filterL10n,
  ) {
    final year = game.publishYear;
    final type = contentTypeLabel(filterL10n, game.contentType);
    return [
      if (type != null) sameFact(type),
      if (year != null)
        sameFact(l10n.catalogDetailPublished(yearText(filterL10n, year))),
      ...playFacts(l10n, filterL10n, game),
    ];
  }
}
