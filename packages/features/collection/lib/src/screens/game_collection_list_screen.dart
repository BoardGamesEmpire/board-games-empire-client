import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_collection/l10n/game_collection_localizations.dart';

import '../bloc/game_collection_list_bloc.dart';
import '../bloc/game_collection_list_event.dart';
import '../bloc/game_collection_list_state.dart';
import '../sync/game_collection_hydration_status.dart';

/// The collection list (#44): every game the signed-in user owns, read
/// reactively from the local cache.
///
/// The household list's shape (`HouseholdListScreen`): the caller resolves
/// the repository, the optional hydration stream and the callbacks, and the
/// screen owns its bloc. Loading, empty, rows and error come from a sealed
/// state; a failed refresh is a banner over whatever the cache holds, with
/// a retry where the composition can run one, and it stays up until a pass
/// completes. Only a retry the user pressed is narrated; passes started by
/// entry, reconnect or resume are not.
///
/// ## The page is thin (#44)
///
/// The list itself is [GameCollectionListSliver], and this screen is a
/// `BgePage` around it plus the bloc it reads. #46's two-pane form can host
/// the sliver beside the detail screen without this page's app bar.
///
/// ## Rows are content until there is somewhere to go (#44)
///
/// Without [onOpen] a row is inert content, not a focus stop: a tap that
/// leads nowhere is worse than no tap (#269). #46 wires it.
class GameCollectionListScreen extends StatelessWidget {
  const GameCollectionListScreen({
    required this.repository,
    this.hydration,
    this.onOpen,
    this.onRetry,
    this.onEnter,
    super.key,
  });

  /// Key on the first-fill spinner.
  static const Key loadingKey = Key('collection_list.loading');

  /// Key on the empty state.
  static const Key emptyKey = Key('collection_list.empty');

  /// Key on the couldn't-refresh banner.
  static const Key refreshBannerKey = Key('collection_list.refresh_banner');

  /// Key on the banner's retry button.
  static const Key refreshRetryKey = Key('collection_list.refresh_retry');

  /// Key on the failed-read surface.
  static const Key errorKey = Key('collection_list.error');

  /// Key on every thumbnail placeholder.
  static const Key thumbnailPlaceholderKey = Key(
    'collection_list.thumbnail_placeholder',
  );

  /// Per-row key: `collection_list.row_<entryId>`.
  static Key rowKey(String entryId) => Key('collection_list.row_$entryId');

  /// Per-row thumbnail key: `collection_list.thumbnail_<entryId>`.
  static Key thumbnailKey(String entryId) =>
      Key('collection_list.thumbnail_$entryId');

  /// The user-session collection repository. Read-only here.
  final GameCollectionRepository repository;

  /// What the hydrate is doing, when this composition runs one. Null reads
  /// as settled rather than as loading forever.
  final Stream<GameCollectionHydration>? hydration;

  /// Opens one entry, or null where there is nowhere to open it. Takes the
  /// id rather than the row, because the destination re-reads the cache.
  final void Function(BuildContext context, String entryId)? onOpen;

  /// Runs one more hydrate pass, or null where this composition has none.
  /// Absent, the banner still reports a failed refresh and offers nothing to
  /// press.
  final Future<void> Function()? onRetry;

  /// Asks for a stale re-hydrate when this screen is entered (#44).
  /// Fire-and-forget: the caller owns the error handling, and what it
  /// starts is not narrated.
  final VoidCallback? onEnter;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<GameCollectionListBloc>(
      create: (_) {
        final bloc = GameCollectionListBloc(
          repository: repository,
          hydration: hydration,
          onRetry: onRetry,
        );
        // Here, not in the route builder: `create` runs once per entry,
        // whereas go_router re-runs a route's builder on every router
        // rebuild (#300). After the bloc, so its subscription is in
        // place before the pass can report anything.
        onEnter?.call();
        return bloc;
      },
      child: _GameCollectionListPage(onOpen: onOpen),
    );
  }
}

class _GameCollectionListPage extends StatelessWidget {
  const _GameCollectionListPage({this.onOpen});

  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    // The row count, for "item 3 of 9". The page owns the scroll view, so
    // the page passes it (#210).
    final rowCount = context.select<GameCollectionListBloc, int?>(
      (bloc) => switch (bloc.state) {
        GameCollectionListReady(:final items) when items.isNotEmpty =>
          items.length,
        _ => null,
      },
    );

    return BgePage.slivers(
      title: Text(l10n.collectionListTitle),
      // A list surface, so the wider measure.
      width: BgePageWidth.pane,
      semanticChildCount: rowCount,
      slivers: [GameCollectionListSliver(onOpen: onOpen)],
    );
  }
}

/// The collection list's content, as one sliver (#44).
///
/// Reads a [GameCollectionListBloc] from context. [GameCollectionListScreen]
/// provides one inside a page; a host such as #46's two-pane form provides
/// its own and puts this in its own scroll view. The host owns that scroll
/// view, so it also owns its `semanticChildCount`.
class GameCollectionListSliver extends StatelessWidget {
  const GameCollectionListSliver({this.onOpen, super.key});

  /// See [GameCollectionListScreen.onOpen].
  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final canRetry = context.read<GameCollectionListBloc>().canRetry;

    return BlocBuilder<GameCollectionListBloc, GameCollectionListState>(
      builder: (context, state) => SliverMainAxisGroup(
        slivers: [
          if (state
              case GameCollectionListReady(
                :final refreshFailed,
                :final refreshing,
              )
              when refreshFailed || refreshing)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
                child: _RefreshBanner(
                  key: GameCollectionListScreen.refreshBannerKey,
                  refreshing: refreshing,
                  onRetry: canRetry
                      ? () => context.read<GameCollectionListBloc>().add(
                          const GameCollectionListRetryRequested(),
                        )
                      : null,
                ),
              ),
            ),
          switch (state) {
            GameCollectionListLoading() => _LoadingSliver(
              message: l10n.collectionListLoading,
            ),
            GameCollectionListError() => _ErrorSliver(
              message: l10n.collectionListError,
            ),
            GameCollectionListReady(:final items) when items.isEmpty =>
              const _EmptySliver(),
            GameCollectionListReady(:final items) => SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) =>
                  _CollectionRow(item: items[index], onOpen: onOpen),
            ),
          },
        ],
      ),
    );
  }
}

/// One entry (#44): the thumbnail, the title line, the detail line and
/// the favorite, as one semantics node.
class _CollectionRow extends StatelessWidget {
  const _CollectionRow({required this.item, this.onOpen});

  final GameCollectionListItem item;
  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final entry = item.entry;
    final open = onOpen;

    final subtitle = item.subtitle;
    final title = subtitle == null || subtitle.isEmpty
        ? item.title
        : l10n.collectionListTitleWithSubtitle(item.title, subtitle);

    final rating = entry.rating;
    final lastPlayed = entry.lastPlayed;
    // Each part as it is shown and as it is spoken. Only the rating
    // differs: "7/10" read aloud is "seven slash ten".
    final details = <({String shown, String spoken})>[
      _same(item.platformName),
      _same(switch (entry.medium) {
        GameMedium.physical => l10n.collectionListMediumPhysical,
        GameMedium.digital => l10n.collectionListMediumDigital,
      }),
      if (entry.quantity > 1)
        _same(l10n.collectionListQuantity(entry.quantity)),
      if (rating != null)
        (
          shown: l10n.collectionListRating(rating),
          spoken: l10n.collectionListRatingSpoken(rating),
        ),
      // The server stamps it in UTC; the user played it on their own day.
      if (lastPlayed != null)
        _same(l10n.collectionListLastPlayed(lastPlayed.toLocal())),
    ];

    // MergeSemantics rather than a Semantics container: a tappable ListTile
    // builds an InkWell with its own node, and merging keeps the tap action
    // and the words on one node (the household row's reasoning).
    return MergeSemantics(
      key: GameCollectionListScreen.rowKey(entry.id),
      child: ListTile(
        // Without an onTap the tile's InkWell has no handler, so it is
        // disabled: no tap action, and not a focus stop under ordinary
        // keyboard navigation. That is the inert row #44 wants.
        onTap: open == null ? null : () => open(context, entry.id),
        leading: BgeThumbnail(
          key: GameCollectionListScreen.thumbnailKey(entry.id),
          url: item.thumbnail,
          placeholderIcon: Icons.casino_outlined,
          placeholderKey: GameCollectionListScreen.thumbnailPlaceholderKey,
        ),
        title: Text(title),
        // Joined differently for the eye and the ear: a screen reader
        // would read the visual separator's symbol out.
        subtitle: Text(
          details.map((d) => d.shown).join(l10n.collectionListDetailSeparator),
          semanticsLabel: details
              .map((d) => d.spoken)
              .join(l10n.collectionListDetailSpokenSeparator),
        ),
        trailing: entry.hasFavorited
            ? Icon(Icons.favorite, semanticLabel: l10n.collectionListFavorite)
            : null,
      ),
    );
  }

  static ({String shown, String spoken}) _same(String text) =>
      (shown: text, spoken: text);
}

/// The stale-data banner and its retry: the household list's
/// (`HouseholdRefreshBanner`), with this feature's copy.
///
/// The failed copy names no cause, because the hydrate reports one
/// undifferentiated failure. While a pass the user asked for runs, the
/// button stays in place, disabled, with the in-progress label rather than
/// a bare spinner: a control that disappears mid-interaction moves focus.
class _RefreshBanner extends StatelessWidget {
  const _RefreshBanner({required this.refreshing, this.onRetry, super.key});

  final bool refreshing;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final retry = onRetry;

    return BgeInlineBanner(
      tone: refreshing ? BgeBannerTone.info : BgeBannerTone.warning,
      message: refreshing
          ? l10n.collectionRefreshInProgress
          : l10n.collectionListRefreshFailed,
      // Furniture for as long as the data stays stale, already at the top
      // of the viewport.
      reveal: false,
      action: retry == null
          ? null
          : TextButton.icon(
              key: GameCollectionListScreen.refreshRetryKey,
              onPressed: refreshing ? null : retry,
              icon: refreshing
                  ? const _RetrySpinner()
                  : const Icon(Icons.refresh),
              label: Text(
                refreshing
                    ? l10n.collectionRefreshInProgress
                    : l10n.collectionRefreshRetry,
              ),
            ),
    );
  }
}

/// The retry button's in-flight icon, scaled with the label beside it and
/// silent to a screen reader: the label announces the state.
class _RetrySpinner extends StatelessWidget {
  const _RetrySpinner();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: BgeTextScale.clampedOf(context)
          .scale(BgeTokens.of(context).spaceMd),
      child: const CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

class _LoadingSliver extends StatelessWidget {
  const _LoadingSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      key: GameCollectionListScreen.loadingKey,
      child: Semantics(
        liveRegion: true,
        label: message,
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}

/// No games. Offers nothing to press: there is no add flow yet, and whether
/// one starts here is #45's call.
class _EmptySliver extends StatelessWidget {
  const _EmptySliver();

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final theme = Theme.of(context);

    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        key: GameCollectionListScreen.emptyKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.collectionListEmptyTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const BgeGap.sm(),
            Text(
              l10n.collectionListEmptyBody,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorSliver extends StatelessWidget {
  const _ErrorSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: BgeInlineBanner(
        key: GameCollectionListScreen.errorKey,
        tone: BgeBannerTone.error,
        message: message,
      ),
    ),
  );
}
