import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/screens/game_detail_collection.dart';
import 'package:game_catalog/src/screens/game_detail_screen.dart';
import 'package:game_catalog/src/widgets/platform_ownership.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The platforms a game is on, as chips that say which of them the user owns
/// it on, and one button to add it on another (#708).
///
/// ## The chips
///
/// A platform the user owns the game on is a filled chip with a check, and
/// opens the user's copy there through [GameDetailCollection.onOpenOwned]:
/// one entry, or both when they own it as a physical and a digital copy. Any
/// other platform is an outlined chip, and opens the add with that platform
/// chosen. Fill against outline is what the eye sees, and the check and each
/// chip's spoken name carry the meaning, so colour is never the only sign.
/// The legend under the chips draws the same check, at the same size.
///
/// A chip focused from the keyboard is ringed, owned or not, because a focus
/// tint barely shows on a filled chip. See [_ChipSlot] for where the ring and
/// the tap target go.
///
/// ## The add
///
/// One button under the chips opens the add on whichever platform still has
/// a medium free. Both the button and an unowned chip hand the add the
/// platforms as they stand at the press, and the add lists those. Once the
/// user owns the game everywhere in both mediums there is nothing left to
/// add, so the button goes: a lasting state, not a busy one. Offline it
/// stays, as an add is queued. Focus on the button as it goes moves to the
/// chip of the last platform it offered, which the user has just filled.
///
/// ## Until ownership is known
///
/// Ownership comes from [GameDetailCollection.watchOwned], over the
/// collection the device holds, so it follows the collection while the page
/// is open. Before the watch first answers, the chips are plain labels with
/// no action, and there is no key and no button, so a screen reader never
/// hears "not in your collection" of a copy the user owns. Without a
/// [collection] they stay that way, as the quick look's are.
///
/// After the watch fails the chips are plain too, since ownership is still
/// unknown, but the button comes back offering every platform in either
/// medium, as the page did before it knew what the user owns. The add's own
/// note says so if the copy chosen is already there.
class GameDetailPlatforms extends StatefulWidget {
  const GameDetailPlatforms({
    required this.game,
    required this.platformGames,
    this.collection,
    super.key,
  });

  final Game game;

  /// The platform games [game] is on. Not empty.
  final List<PlatformGame> platformGames;

  /// What the page can do with the user's collection, or null where the
  /// session has none.
  final GameDetailCollection? collection;

  @override
  State<GameDetailPlatforms> createState() => _GameDetailPlatformsState();
}

class _GameDetailPlatformsState extends State<GameDetailPlatforms> {
  static final BgeLogger _log = BgeLogger('bge.catalog.detail.ownership');

  /// The check's size: a Material chip's avatar size, set on both the chips
  /// and the legend so they draw the same mark.
  static const double _checkSize = 18;

  /// The platform game ids the watch is over.
  late Set<String> _ids;

  StreamSubscription<List<GameCollection>>? _watch;

  /// The user's entries on [_ids], or null until the watch answers, and once
  /// it fails.
  List<GameCollection>? _entries;

  /// Whether the watch has failed since it was last subscribed.
  bool _watchFailed = false;

  final FocusNode _addFocus = FocusNode(debugLabel: 'game detail add');

  /// Each chip's focus node, by platform game id, so focus can be handed to
  /// one when the button goes.
  final Map<String, FocusNode> _chipFocus = {};

  @override
  void initState() {
    super.initState();
    _ids = _idsOf(widget.platformGames);
    _subscribe();
  }

  @override
  void didUpdateWidget(GameDetailPlatforms oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh hands over a new list of the same platforms, and the shell a
    // new collection on every build of the route: neither changes what is
    // watched. A new platform does, and the last answer says nothing of it.
    final ids = _idsOf(widget.platformGames);
    final hadCollection = oldWidget.collection != null;
    if (setEquals(ids, _ids) && hadCollection == (widget.collection != null)) {
      return;
    }
    _ids = ids;
    unawaited(_watch?.cancel());
    _watch = null;
    _entries = null;
    _watchFailed = false;
    for (final id in _chipFocus.keys.toList()) {
      if (!ids.contains(id)) _chipFocus.remove(id)!.dispose();
    }
    _subscribe();
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    _addFocus.dispose();
    for (final node in _chipFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _chipFocusOf(String platformGameId) => _chipFocus.putIfAbsent(
    platformGameId,
    () => FocusNode(debugLabel: 'game detail chip $platformGameId'),
  );

  /// What the button offers for [entries]: the free mediums where ownership
  /// is known, every medium after the watch failed, and nothing before it
  /// answers.
  List<CollectionAddOption> _addOptionsFor(List<GameCollection>? entries) {
    if (widget.collection == null) return const [];
    if (entries == null && !_watchFailed) return const [];
    return PlatformOwnership.of(
      platformGames: widget.platformGames,
      entries: entries ?? const [],
    ).addOptions;
  }

  /// Hands the button's focus on as [next] takes the button away: to the
  /// chip of the last platform it offered, the stop just before it and the
  /// copy just filled. Left to go with the button, focus would fall back on
  /// whatever had it before, or on nothing.
  ///
  /// Runs before the frame that takes the button away, while it still has
  /// focus, and hands it on after that frame, unless the user has moved focus
  /// meanwhile or the button is back.
  void _handOffAddFocus(List<GameCollection> next) {
    if (!_addFocus.hasFocus || _addOptionsFor(next).isNotEmpty) return;
    final before = _addOptionsFor(_entries);
    if (before.isEmpty) return;
    final target = before.last.platformGame.id;
    final focused = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(context, untouched: focused)) return;
      if (_addOptionsFor(_entries).isNotEmpty) return;
      _chipFocus[target]?.requestFocus();
    });
  }

  static Set<String> _idsOf(List<PlatformGame> platformGames) => {
    for (final platformGame in platformGames) platformGame.id,
  };

  void _subscribe() {
    final collection = widget.collection;
    if (collection == null) return;
    _watch = collection
        .watchOwned(_ids)
        .listen(
          (entries) {
            _handOffAddFocus(entries);
            setState(() {
              _entries = entries;
              _watchFailed = false;
            });
          },
          onError: (Object error, StackTrace stackTrace) {
            _log.warn(
              'Watching what the user owns of a game failed',
              error: error,
              stackTrace: stackTrace,
            );
            setState(() {
              _entries = null;
              _watchFailed = true;
            });
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final collection = widget.collection;
    final entries = _entries;
    final ownership = collection == null || entries == null
        ? null
        : PlatformOwnership.of(
            platformGames: widget.platformGames,
            entries: entries,
          );
    final ownsAny =
        ownership != null &&
        widget.platformGames.any((p) => ownership.owns(p.id));
    final addOptions = _addOptionsFor(entries);

    // One shape whether or not ownership is known, so the chips' row keeps
    // its element as the answer lands; the legend and the button follow it.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // No spacing of its own: each slot's margin, spaceXs a side, makes
        // the spaceSm between two chips. Drawn back by that margin so that
        // the chips line up with the heading, the legend and the button, and
        // only a ring stands in the page's padding.
        Transform.translate(
          offset: Offset(
            Directionality.of(context) == TextDirection.rtl
                ? tokens.spaceXs
                : -tokens.spaceXs,
            0,
          ),
          child: Wrap(
            runSpacing: tokens.spaceSm,
            children: [
              for (final platformGame in widget.platformGames)
                if (collection == null || ownership == null)
                  _ChipSlot(
                    key: GameDetailScreen.platformKey(platformGame.id),
                    chip: Chip(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      label: GameFilterChipLabel(platformGame.platformName),
                    ),
                  )
                else
                  _ChipSlot(
                    key: GameDetailScreen.platformKey(platformGame.id),
                    ringed: true,
                    chip: _chip(
                      context,
                      l10n,
                      platformGame,
                      ownership,
                      collection,
                    ),
                  ),
            ],
          ),
        ),
        if (ownsAny) ...[
          const BgeGap.sm(),
          // The chips' check, on the page's surface, and decoration only: the
          // words say it, and each chip's spoken name says it again.
          Row(
            key: GameDetailScreen.ownedLegendKey,
            mainAxisSize: MainAxisSize.min,
            spacing: tokens.spaceSm,
            children: [
              Icon(
                Icons.check,
                size: _checkSize,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              Flexible(
                child: Text(
                  l10n.catalogDetailOwnedLegend,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
        if (collection != null && addOptions.isNotEmpty) ...[
          const BgeGap.md(),
          FilledButton.tonal(
            key: GameDetailScreen.addKey,
            focusNode: _addFocus,
            onPressed: () => collection.onAdd(context, widget.game, addOptions),
            child: Text(l10n.catalogDetailAddToCollection),
          ),
        ],
      ],
    );
  }

  /// A platform's chip: filled and checked where the user owns the game,
  /// outlined where they don't, each named for a screen reader by what it
  /// does.
  Widget _chip(
    BuildContext context,
    GameCatalogLocalizations l10n,
    PlatformGame platformGame,
    PlatformOwnership ownership,
    GameDetailCollection collection,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final name = platformGame.platformName;
    final owned = ownership.entriesOn(platformGame.id);
    final game = widget.game;

    // The spoken name goes on the label, where it replaces the shown name in
    // the chip's own node, which keeps the chip's press and focus for a
    // screen reader.
    if (owned.isNotEmpty) {
      return ActionChip(
        focusNode: _chipFocusOf(platformGame.id),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: Icon(Icons.check, size: _checkSize, color: scheme.onPrimary),
        label: GameFilterChipLabel(
          name,
          semanticsLabel: l10n.catalogDetailPlatformOwnedSpoken(name),
        ),
        labelStyle: TextStyle(color: scheme.onPrimary),
        backgroundColor: scheme.primary,
        side: BorderSide.none,
        onPressed: () => collection.onOpenOwned(context, [
          for (final entry in owned)
            GameCollectionListItem(
              entry: entry,
              gameId: game.id,
              title: game.title,
              subtitle: game.subtitle,
              platformName: name,
              thumbnail:
                  platformGame.thumbnail ??
                  platformGame.image ??
                  game.thumbnail ??
                  game.image,
            ),
        ]),
      );
    }
    return ActionChip(
      focusNode: _chipFocusOf(platformGame.id),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      label: GameFilterChipLabel(
        name,
        semanticsLabel: l10n.catalogDetailPlatformNotOwnedSpoken(name),
      ),
      labelStyle: TextStyle(color: scheme.primary),
      side: BorderSide(color: scheme.primary),
      onPressed: () => collection.onAdd(
        context,
        game,
        ownership.addOptions,
        platformGameId: platformGame.id,
      ),
    );
  }
}

/// One chip on the page, at the 48 dp tap target, ringed while it has focus
/// from the keyboard (#708).
///
/// A Material chip pads itself out to the tap target, and a ring drawn around
/// that would stand off the chip above and below. So [chip] is built without
/// that padding, and the ring is drawn [BgeTokens.spaceXs] out from the
/// chip's own edge, following its corners. There it stands on the page's
/// surface, so it shows beside a chip filled in `primary` as well as an
/// outlined one. The tap target goes back on outside the ring, 48 dp square
/// at the least, and a press anywhere in it reaches the chip, as a padded
/// Material chip's does.
///
/// The first slot in a run has its start margin drawn into the page's
/// padding, outside every box above it, where no press can reach it. So the
/// target is that margin wider than 48 dp, and 48 dp of it still takes a
/// press.
///
/// A plain chip is laid out the same with no ring, so the chips don't move
/// when ownership lands.
class _ChipSlot extends StatelessWidget {
  const _ChipSlot({required this.chip, this.ringed = false, super.key});

  /// A chip built with [MaterialTapTargetSize.shrinkWrap].
  final Widget chip;

  /// Whether [chip] takes focus, and so is ringed while it has it.
  final bool ringed;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);

    Widget spaced(ValueChanged<bool>? onFocusChange) => Padding(
      padding: EdgeInsets.all(tokens.spaceXs),
      child: onFocusChange == null
          ? chip
          // Told when the chip's own focus node gains or loses the focus;
          // adds no focus stop and no semantics of its own.
          : Focus(
              canRequestFocus: false,
              skipTraversal: true,
              includeSemantics: false,
              onFocusChange: onFocusChange,
              child: chip,
            ),
    );

    final slot = _ChipTapTarget(
      minWidth: tokens.minTapTarget + tokens.spaceXs,
      minHeight: tokens.minTapTarget,
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: ringed
            ? BgeFocusRing(
                // The chip's corner, Material's 8 dp, plus the spaceXs margin
                // is radiusMd's 12 dp, so the ring runs parallel to the
                // chip's edge. The chips keep the theme's own shape, as the
                // quick look's do, and a test holds the two together.
                borderRadius: BorderRadius.circular(tokens.radiusMd),
                builder: (context, onFocusChange) => spaced(onFocusChange),
              )
            : spaced(null),
      ),
    );
    // One node the size of the tap target, as a padded chip's is.
    return ringed ? MergeSemantics(child: slot) : slot;
  }
}

/// Holds its child to [minWidth] by [minHeight] at the least, and sends a
/// press anywhere in it to the child, as a padded Material chip's tap target
/// does.
///
/// A press beside the chip goes to the chip's middle row, as Material's does,
/// so the press lands where it was made across a chip's width. One beyond
/// the chip's ends, in a target wider than a short chip, goes to the middle.
class _ChipTapTarget extends SingleChildRenderObjectWidget {
  const _ChipTapTarget({
    required this.minWidth,
    required this.minHeight,
    required super.child,
  });

  final double minWidth;
  final double minHeight;

  BoxConstraints get _constraints =>
      BoxConstraints(minWidth: minWidth, minHeight: minHeight);

  @override
  _RenderChipTapTarget createRenderObject(BuildContext context) =>
      _RenderChipTapTarget(_constraints);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderChipTapTarget renderObject,
  ) {
    renderObject.additionalConstraints = _constraints;
  }
}

class _RenderChipTapTarget extends RenderConstrainedBox {
  _RenderChipTapTarget(BoxConstraints additionalConstraints)
    : super(additionalConstraints: additionalConstraints);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null || !size.contains(position)) return false;
    bool pressAt(Offset point) => result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(point),
      position: position,
      hitTest: (result, _) => child.hitTest(result, position: point),
    );
    return pressAt(Offset(position.dx, size.height / 2)) ||
        pressAt(size.center(Offset.zero));
  }
}
