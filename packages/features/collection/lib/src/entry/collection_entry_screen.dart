import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/entry/collection_entry_bloc.dart';
import 'package:game_collection/src/entry/collection_entry_event.dart';
import 'package:game_collection/src/entry/collection_entry_state.dart';
import 'package:game_collection/src/entry/edit_collection_entry_sheet.dart';
import 'package:game_collection/src/entry/remove_from_collection_dialog.dart';
import 'package:game_collection/src/medium_label.dart';
import 'package:game_collection/src/sync/collection_sync.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One entry of the collection (#46): the game it is a copy of, the copy's
/// fields, and the app bar's Edit and Remove.
///
/// ## The page is thin
///
/// The content is [CollectionEntryDetail], and this screen is a `BgePage`
/// around it, plus the bloc it reads, the app bar's actions and what is said
/// of their outcomes. #680's two-pane form can host the detail beside the
/// list without this page, as it hosts the list's sliver without the list's.
///
/// The app bar has no title. The content's heading, the game's title, names
/// the screen; a section name beside Edit and Remove was cut to its first
/// letter at 320dp and 2x text.
///
/// ## Edit and Remove
///
/// Each is named by its visible label, which every screen reader reads:
/// VoiceOver doesn't take a tooltip as a name. Both are there while the entry
/// is live. While a save or a removal is under way both stay in place but do
/// nothing, read as disabled, and keep the keyboard focus a user left on
/// them (STYLE_GUIDE §5, "Disable, don't hide"). The one under way says so
/// in its label, "Saving…" or "Removing…", as it starts. So the only edit
/// sheet that can be open when a save ends is the one that submitted it.
///
/// ## What it says
///
/// Every outcome of an edit or a removal is said here, in a SnackBar on the
/// app's messenger, since the edit sheet can be dismissed while its save is
/// under way:
///
/// - A save says whether the server has it, it waits to sync, or the server
///   refused it. A save that changed nothing says nothing.
/// - A failed save is the open sheet's to show. One that fails after its
///   sheet was dismissed is said here, so it is never silent.
/// - A removal that lands while this screen is the top route closes it, and
///   is said over the page beneath. While a removal is under way, Edit,
///   Remove and "Game details" do nothing, so nothing of this screen's own
///   opens over it. One that lands while another route covers it is said
///   over that route, and the screen stays, showing the entry gone, with
///   nothing held. A failed removal is said, and the screen stays.
///
/// The screen holds its bloc, not a `BlocProvider`. One left while a save or
/// a removal is under way keeps the bloc until it settles, says the outcome
/// over the page the user went to (a failure too), and then closes it, as
/// #45's dismissed add does. A removal that settles after the user left
/// closes nothing.
///
/// ## Removed elsewhere
///
/// An entry removed on another device, which arrives with a hydrate, shows
/// the gone state with nothing to edit or remove. The screen doesn't leave on
/// its own: it says why the entry went. An entry the cache doesn't hold yet
/// is loading while [hydration] says the hydrate could still bring it (see
/// [CollectionEntryBloc]).
class CollectionEntryScreen extends StatefulWidget {
  const CollectionEntryScreen({
    required this.repository,
    required this.sender,
    required this.entryId,
    this.hydration,
    this.onOpenGame,
    super.key,
  });

  /// Key on the app bar's Edit.
  static const Key editKey = Key('collection_entry.edit');

  /// Key on the app bar's Remove.
  static const Key removeKey = Key('collection_entry.remove');

  /// Key on the content's "Game details".
  static const Key gameDetailsKey = Key('collection_entry.game_details');

  /// Key on the gone state.
  static const Key goneKey = Key('collection_entry.gone');

  /// Key on the couldn't-load state.
  static const Key errorKey = Key('collection_entry.error');

  /// Key on the couldn't-load state's retry.
  static const Key retryKey = Key('collection_entry.retry');

  /// Key on the spinner shown until the entry is read.
  static const Key loadingKey = Key('collection_entry.loading');

  /// The user-session collection repository.
  ///
  /// It and [sender] must be the active session's: the caller resolves them
  /// per route build. One held across a session change is disposed, and
  /// throws.
  final GameCollectionRepository repository;

  /// Sends an edit or a removal at once, as every write that queues one does.
  final SyncOperationSender sender;

  /// The entry shown.
  final String entryId;

  /// The collection hydrate's status, or null where the composition runs
  /// none. Read once, when the screen is first built.
  final Stream<Hydration>? hydration;

  /// See [CollectionEntryDetail.onOpenGame].
  final void Function(BuildContext context, String gameId)? onOpenGame;

  @override
  State<CollectionEntryScreen> createState() => _CollectionEntryScreenState();
}

class _CollectionEntryScreenState extends State<CollectionEntryScreen> {
  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the route: a save or a removal still under way then would never say how
  /// it ended. See [dispose].
  late final CollectionEntryBloc _bloc;

  /// The app's messenger and this screen's strings, captured while the
  /// screen is mounted: an outcome that settles after it is gone is said
  /// with them, and [dispose] can't look them up.
  late ScaffoldMessengerState _messenger;
  late GameCollectionLocalizations _l10n;

  /// Whether this screen's edit sheet is open: from its opening until it
  /// starts to close, when the sheet's future completes. A save that fails
  /// meanwhile is the sheet's to show.
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    _bloc = CollectionEntryBloc(
      repository: widget.repository,
      sender: widget.sender,
      entryId: widget.entryId,
      hydration: widget.hydration,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
    _l10n = GameCollectionLocalizations.of(context);
  }

  @override
  void dispose() {
    // Left with a save or a removal under way: it settles, is said, and the
    // bloc closes then. Otherwise there is nothing left to say.
    if (_underWay(_bloc.state.action)) {
      unawaited(_sayWhenSettled(_bloc));
    } else {
      unawaited(_bloc.close());
    }
    super.dispose();
  }

  static bool _underWay(CollectionEntryAction action) =>
      action == CollectionEntryAction.saving ||
      action == CollectionEntryAction.removing;

  /// Waits for the save or removal under way, says how it ended over
  /// whatever page is showing now, and closes [bloc]. Pops nothing: the
  /// screen is already gone.
  Future<void> _sayWhenSettled(CollectionEntryBloc bloc) async {
    try {
      _say(await bloc.stream.firstWhere((state) => !_underWay(state.action)));
    } finally {
      await bloc.close();
    }
  }

  /// Says [state]'s outcome in a SnackBar on the app's messenger, if it has
  /// one to say. The messenger is the app's, so what it shows outlives this
  /// route and lands on the page beneath. Both the listener and [dispose]'s
  /// late outcome say it here.
  void _say(CollectionEntryState state) {
    final message = _outcomeOf(state);
    if (message == null || !_messenger.mounted) return;
    _messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  String? _outcomeOf(CollectionEntryState state) {
    final l10n = _l10n;
    // Read only for a removal's outcome: Remove is offered only once there
    // is an item, and the bloc keeps it through the removal.
    String title() => state.item!.title;

    return switch (state.action) {
      // A save that changed nothing made no call, and says nothing.
      CollectionEntryAction.saved when !state.changed => null,
      CollectionEntryAction.saved => switch (state.sync) {
        CollectionSync.queued => l10n.collectionEntrySavedQueued,
        CollectionSync.refused => l10n.collectionEntryRefused,
        // A save that changed something sent it, so it has a sync; it is in
        // the entry either way.
        CollectionSync.synced || null => l10n.collectionEntrySaved,
      },
      CollectionEntryAction.saveFailed => l10n.editCollectionFailedTitle,
      CollectionEntryAction.removed => switch (state.sync) {
        CollectionSync.queued => l10n.collectionEntryRemovedQueued(title()),
        CollectionSync.refused => l10n.collectionEntryRefused,
        // Null when it was already removed, which is what was asked.
        CollectionSync.synced || null => l10n.collectionEntryRemoved(title()),
      },
      CollectionEntryAction.removeFailed => l10n.collectionEntryRemoveFailed(
        title(),
      ),
      CollectionEntryAction.idle ||
      CollectionEntryAction.saving ||
      CollectionEntryAction.removing => null,
    };
  }

  Future<void> _edit() async {
    _sheetOpen = true;
    try {
      await showEditCollectionEntrySheet(context, bloc: _bloc);
    } finally {
      _sheetOpen = false;
    }
  }

  Future<void> _remove() async {
    // Read before the dialog opens: the screen can go while it is up, and
    // take its context with it.
    final bloc = _bloc;
    final title = bloc.state.item?.title;
    if (title == null) return;
    final confirmed = await showRemoveFromCollectionDialog(
      context,
      title: title,
    );
    if (!confirmed || !mounted) return;
    bloc.add(const CollectionEntryRemoveConfirmed());
  }

  void _onAction(BuildContext context, CollectionEntryState state) {
    switch (state.action) {
      case CollectionEntryAction.idle ||
          CollectionEntryAction.saving ||
          CollectionEntryAction.removing:
        return;
      case CollectionEntryAction.saveFailed when _sheetOpen:
        // The open sheet shows it, and clears it when it next opens.
        return;
      case CollectionEntryAction.removed:
        // Only from the top. The route stays mounted through its exit, and
        // a pop takes whichever route is on top, so a screen already leaving
        // or covered would pop another.
        if (ModalRoute.isCurrentOf(context) ?? true) {
          Navigator.of(context).pop();
          _say(state);
          return;
        }
        _say(state);
        // Covered, or already leaving: it stays, so nothing may stay held. The
        // bloc shows the entry gone once its row is.
        _bloc.add(const CollectionEntryActionCleared());
      case CollectionEntryAction.saved ||
          CollectionEntryAction.saveFailed ||
          CollectionEntryAction.removeFailed:
        _say(state);
        // Each outcome is said once. Cleared, the next one is a change the
        // listener sees, even when it equals this one.
        _bloc.add(const CollectionEntryActionCleared());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);

    return BlocProvider<CollectionEntryBloc>.value(
      value: _bloc,
      child: BlocListener<CollectionEntryBloc, CollectionEntryState>(
        listenWhen: (previous, current) => previous.action != current.action,
        listener: _onAction,
        child: BlocBuilder<CollectionEntryBloc, CollectionEntryState>(
          buildWhen: (previous, current) =>
              previous.view != current.view ||
              previous.action != current.action,
          builder: (context, state) {
            final action = state.action;
            final ready = state.view == CollectionEntryView.ready;
            final saving = action == CollectionEntryAction.saving;
            final removing =
                action == CollectionEntryAction.removing ||
                action == CollectionEntryAction.removed;
            final held = saving || removing;

            return BgePage(
              // An empty title rather than none, which would drop the app
              // bar and its back button with it. The game's title, the
              // content's heading, names the screen.
              title: const SizedBox.shrink(),
              actions: [
                if (ready)
                  _ActionsBesideBack(
                    // The one whose label grows gives way: Edit's while it
                    // says "Saving…", Remove's otherwise.
                    yielding: saving ? 0 : 1,
                    children: [
                      _HeldButton(
                        buttonKey: CollectionEntryScreen.editKey,
                        label: l10n.collectionEntryEdit,
                        progressLabel: saving
                            ? l10n.editCollectionInProgress
                            : null,
                        onPressed: held ? null : () => unawaited(_edit()),
                      ),
                      _HeldButton(
                        buttonKey: CollectionEntryScreen.removeKey,
                        label: l10n.collectionEntryRemove,
                        progressLabel: removing
                            ? l10n.collectionEntryRemoving
                            : null,
                        onPressed: held ? null : () => unawaited(_remove()),
                      ),
                    ],
                  ),
              ],
              // A message is centred; the entry starts at the top.
              centerVertically: !ready,
              child: CollectionEntryDetail(onOpenGame: widget.onOpenGame),
            );
          },
        ),
      ),
    );
  }
}

/// One collection entry's content, without its page (#46).
///
/// Reads a [CollectionEntryBloc] from context. [CollectionEntryScreen]
/// provides one inside a page; #680's two-pane form provides its own, puts
/// this in its own scroll view, and offers Edit and Remove its own way.
///
/// ## Each view
///
/// Loading is a spinner, named for a screen reader. Gone (the entry went
/// while it was open) is a message, which a screen reader hears as it
/// appears; it names the game that went. Error is the screen's failure,
/// `BgeErrorState`, whose retry watches the entry again. A live entry is its
/// summary and its fields.
///
/// ## Every field says something
///
/// Copies, rating, plays, last played and comment each have a value for
/// unset ("No rating", "No plays recorded", "Not played yet", "No comment"),
/// so a field left empty reads as empty rather than missing. Favorite and
/// would-play-again are said only when true, as the list's row shows the
/// favorite's heart only then. Plays and the last played date are shown, not
/// edited: the edit sheet doesn't send them (#258).
///
/// A line whose text alone doesn't say what it is (the platform, physical or
/// digital, and the comment) is read with what it is: "Platform: Board game",
/// "Your comment: …". The rating is read in words, as the list reads it.
///
/// Nothing is cut short. Every field wraps, at 320dp with 2x text too.
///
/// ## "Game details"
///
/// Does nothing while a removal is under way, held as Edit and Remove are,
/// so no page opens over the screen the removal is about to close.
class CollectionEntryDetail extends StatelessWidget {
  const CollectionEntryDetail({this.onOpenGame, super.key});

  /// Opens the game's own page, or null where there is none to open. Called
  /// with this context and the entry's game id, and offered as "Game
  /// details" only when set.
  final void Function(BuildContext context, String gameId)? onOpenGame;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);

    return BlocBuilder<CollectionEntryBloc, CollectionEntryState>(
      buildWhen: (previous, current) =>
          previous.view != current.view || previous.item != current.item,
      builder: (context, state) => switch (state.view) {
        CollectionEntryView.loading => Center(
          child: BgeLoadingState(
            key: CollectionEntryScreen.loadingKey,
            label: l10n.collectionEntryLoading,
          ),
        ),
        CollectionEntryView.gone => _Gone(title: state.item?.title),
        CollectionEntryView.error => BgeErrorState(
          key: CollectionEntryScreen.errorKey,
          retryKey: CollectionEntryScreen.retryKey,
          icon: Icons.error_outline,
          title: l10n.collectionEntryError,
          body: l10n.collectionEntryErrorBody,
          retryLabel: l10n.collectionEntryRetry,
          onRetry: () => context.read<CollectionEntryBloc>().add(
            const CollectionEntryRetried(),
          ),
        ),
        // A ready view always has its row.
        CollectionEntryView.ready => _Entry(
          item: state.item!,
          onOpenGame: onOpenGame,
        ),
      },
    );
  }
}

/// The entry went while it was open. Names the game, when it was ever read,
/// above why.
class _Gone extends StatelessWidget {
  const _Gone({this.title});

  final String? title;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final theme = Theme.of(context);
    final title = this.title;

    return Column(
      key: CollectionEntryScreen.goneKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          const BgeGap.md(),
        ],
        // One announcement, heard as it appears, rather than a heading and
        // then a fragment.
        BgeEmptyState(
          title: l10n.collectionEntryGoneTitle,
          body: l10n.collectionEntryGoneBody,
        ),
      ],
    );
  }
}

/// A live entry: the game's thumbnail, title, subtitle and platform, the way
/// to its page, and the copy's fields.
class _Entry extends StatelessWidget {
  const _Entry({required this.item, this.onOpenGame});

  /// Twice the list row's, so the detail shows more of the cover than the
  /// row it was opened from.
  static const double _thumbnailExtent = BgeThumbnail.listExtent * 2;

  final GameCollectionListItem item;
  final void Function(BuildContext context, String gameId)? onOpenGame;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final entry = item.entry;
    final subtitle = item.subtitle;
    final rating = entry.rating;
    final plays = entry.playCount ?? 0;
    final lastPlayed = entry.lastPlayed;
    // A blank one is no comment.
    final comment = switch (entry.comment) {
      final text? when text.trim().isNotEmpty => text,
      _ => null,
    };
    final medium = mediumLabel(l10n, entry.medium);
    final open = onOpenGame;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Above the title rather than beside it, so a long title has the
        // whole width to wrap in at large text.
        BgeThumbnail(
          url: item.thumbnail,
          extent: _thumbnailExtent,
          placeholderIcon: Icons.casino_outlined,
        ),
        const BgeGap.md(),
        // The screen's name: the app bar has no title.
        Semantics(
          header: true,
          child: Text(item.title, style: theme.textTheme.headlineSmall),
        ),
        if (subtitle != null && subtitle.isNotEmpty)
          Text(subtitle, style: theme.textTheme.titleMedium),
        const BgeGap.xs(),
        Text(
          item.platformName,
          semanticsLabel: l10n.collectionEntryPlatformSpoken(item.platformName),
          style: muted,
        ),
        if (open != null) ...[
          const BgeGap.md(),
          // Held while a removal is under way: a page opened over the screen
          // then would keep it from closing when the removal lands.
          BlocSelector<CollectionEntryBloc, CollectionEntryState, bool>(
            selector: (state) =>
                state.action == CollectionEntryAction.removing ||
                state.action == CollectionEntryAction.removed,
            builder: (context, removing) => _HeldButton(
              buttonKey: CollectionEntryScreen.gameDetailsKey,
              label: l10n.collectionEntryGameDetails,
              outlined: true,
              onPressed: removing ? null : () => open(context, item.gameId),
            ),
          ),
        ],
        const BgeGap.lg(),
        _Field(
          icon: switch (entry.medium) {
            GameMedium.physical => Icons.inventory_2_outlined,
            GameMedium.digital => Icons.cloud_outlined,
          },
          text: medium,
          spoken: l10n.collectionEntryMediumSpoken(medium),
        ),
        _Field(
          icon: Icons.layers_outlined,
          text: l10n.collectionListQuantity(entry.quantity),
        ),
        if (rating != null)
          _Field(
            icon: Icons.star,
            text: l10n.collectionListRating(rating),
            // "7/10" read aloud is "seven slash ten".
            spoken: l10n.collectionListRatingSpoken(rating),
          )
        else
          _Field(
            icon: Icons.star_outline,
            text: l10n.addToCollectionRatingNone,
            style: muted,
          ),
        if (entry.hasFavorited)
          _Field(icon: Icons.favorite, text: l10n.collectionListFavorite),
        if (entry.playAgain ?? false)
          _Field(icon: Icons.replay, text: l10n.collectionEntryPlayAgain),
        _Field(
          icon: Icons.casino_outlined,
          text: l10n.collectionEntryPlays(plays),
          style: plays == 0 ? muted : null,
        ),
        _Field(
          icon: Icons.event_outlined,
          // The server stamps it in UTC; the user played it on their own
          // day.
          text: lastPlayed == null
              ? l10n.collectionEntryLastPlayedNever
              : l10n.collectionListLastPlayed(lastPlayed.toLocal()),
          style: lastPlayed == null ? muted : null,
        ),
        _Field(
          icon: Icons.notes,
          text: comment ?? l10n.collectionEntryNoComment,
          spoken: comment == null
              ? null
              : l10n.collectionEntryCommentSpoken(comment),
          style: comment == null ? muted : null,
        ),
      ],
    );
  }
}

/// One of the entry's fields: a decorative icon beside text that wraps.
class _Field extends StatelessWidget {
  const _Field({
    required this.icon,
    required this.text,
    this.spoken,
    this.style,
  });

  final IconData icon;
  final String text;

  /// What a screen reader says in place of [text], when they differ.
  final String? spoken;

  /// The text's style, when not the body's.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Unlabelled, so silent: the text says what the field is.
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const BgeGap.sm(axis: Axis.horizontal),
          Expanded(
            child: Text(
              text,
              semanticsLabel: spoken,
              style: style ?? theme.textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}

/// The app bar's actions, kept to the room beside its back button.
///
/// The bar lays its actions out across its whole width, so a row of them
/// wider than the room beside the back button runs under it, and one wider
/// than the bar overflows. At 320dp and 2x text, "Removing…" beside Edit
/// can be. So the row is held to that room, and the child at [yielding]
/// gives way: its label is ellipsized rather than the row overflowing, as
/// `BgeSubmitButton`'s progress label is. Its node keeps the whole label.
/// The others keep their own width. Every child stays in place whichever
/// gives way, so none loses its state or its focus.
class _ActionsBesideBack extends StatelessWidget {
  const _ActionsBesideBack({required this.yielding, required this.children});

  /// The index of the child that gives way.
  final int yielding;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // The bar's leading slot is a toolbar's height wide (`AppBar`'s default
    // `leadingWidth`), inside the horizontal safe area.
    final room =
        MediaQuery.sizeOf(context).width -
        MediaQuery.paddingOf(context).horizontal -
        kToolbarHeight;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: room),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, child) in children.indexed)
            // A flex of 0 lays the child out at its own width.
            Flexible(flex: index == yielding ? 1 : 0, child: child),
        ],
      ),
    );
  }
}

/// A button that is held, rather than disabled or hidden, while an edit or
/// a removal is under way (STYLE_GUIDE §5, "Disable, don't hide").
///
/// While [onPressed] is null it stays in place, is drawn as a disabled
/// button is, and reads as disabled, but underneath it stays enabled and a
/// press does nothing. A disabled button gives up the focus, so one held
/// under a keyboard user's focus would drop it. While [progressLabel] is
/// set it is shown and read in place of [label], in a live region, so the
/// action under way is said as it starts.
///
/// Its node is built here: the button's own sets its own enabled flag, which
/// a `Semantics` around it can't override. It is named in its label, not by
/// a tooltip, which VoiceOver doesn't read as a name, and says whether it
/// has the focus, as the `Focus` it excludes would. As `BgeShelf`'s move
/// buttons are.
class _HeldButton extends StatefulWidget {
  const _HeldButton({
    required this.buttonKey,
    required this.label,
    required this.onPressed,
    this.progressLabel,
    this.outlined = false,
  });

  /// The key on the button itself.
  final Key buttonKey;

  final String label;

  /// Null while held.
  final VoidCallback? onPressed;

  /// Shown and read in place of [label] while the action is under way.
  final String? progressLabel;

  /// An outlined button in the content, whose label wraps, rather than a
  /// text one in the app bar, whose label is one line.
  final bool outlined;

  @override
  State<_HeldButton> createState() => _HeldButtonState();
}

class _HeldButtonState extends State<_HeldButton> {
  // Owned here to say whether it has focus, which the node here has to report
  // now that the one `Focus` builds is excluded.
  final FocusNode _focusNode = FocusNode(debugLabel: 'Collection entry action');

  static void _ignore() {}

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed;
    final progressLabel = widget.progressLabel;
    final shown = progressLabel ?? widget.label;
    final style = onPressed == null ? _heldStyle(context) : null;
    // The content's outlined button wraps, as the content does. The app
    // bar's are one line, ellipsized where the room runs out (see
    // [_ActionsBesideBack]); the node below reads the whole label.
    final child = widget.outlined
        ? Text(shown)
        : Text(
            shown,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          );
    final button = widget.outlined
        ? OutlinedButton(
            key: widget.buttonKey,
            focusNode: _focusNode,
            style: style,
            onPressed: onPressed ?? _ignore,
            child: child,
          )
        : TextButton(
            key: widget.buttonKey,
            focusNode: _focusNode,
            style: style,
            onPressed: onPressed ?? _ignore,
            child: child,
          );

    return ListenableBuilder(
      listenable: _focusNode,
      builder: (context, button) => Semantics(
        container: true,
        button: true,
        enabled: onPressed != null,
        focusable: true,
        focused: _focusNode.hasPrimaryFocus,
        liveRegion: progressLabel != null,
        label: shown,
        onTap: onPressed,
        // As `Focus` has it: withheld on iOS (flutter/flutter#150030).
        onFocus: defaultTargetPlatform == TargetPlatform.iOS
            ? null
            : _focusNode.requestFocus,
        excludeSemantics: true,
        child: button,
      ),
      child: button,
    );
  }

  /// Drawn as a disabled button is, and with no answer to a press or a
  /// hover. The focus overlay stays, since it is how a keyboard user sees
  /// where they are.
  ButtonStyle _heldStyle(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(color),
      side: widget.outlined
          ? WidgetStatePropertyAll(BorderSide(color: color))
          : null,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? null
            : color.withValues(alpha: 0),
      ),
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.basic),
      splashFactory: NoSplash.splashFactory,
      enableFeedback: false,
    );
  }
}
