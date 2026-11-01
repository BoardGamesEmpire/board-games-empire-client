import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

import '../bloc/language_link_list_bloc.dart';
import '../bloc/language_link_list_event.dart';
import '../bloc/language_link_list_state.dart';
import 'data_gateway_status.dart';
import 'language_tag_picker_dialog.dart';

/// A DataGateway's language worklist (#457): the values it uses for languages
/// under a status filter, a page at a time, each with the actions that settle
/// it.
///
/// A group of slivers for the DataGateway's own page, read from the
/// [LanguageLinkListBloc] that page provides. [remote] is only for the
/// language picker, which reads the server's languages itself. What an action
/// answered shows apart from the rows, in a [LanguageLinkOutcomeBanner] that
/// the page puts in its footer.
///
/// ## Keeping keyboard focus
///
/// A worklist is worked row by row, so an action must not send a keyboard or
/// switch user back to the top of the page. A row's menu gives way to a spinner
/// while its action runs, which takes focus with it, so:
///
/// - When the action starts, focus goes to the page rather than along with the
///   menu. Left to go with it, focus would land on whatever had it before, such
///   as the row above, and look as if the user had put it there.
/// - When the action ends, focus comes back to the row's menu if the row is
///   still listed, or else the menu of the row now in its place, or else the
///   one before it. Not if the user has focused something else meanwhile: only
///   the row last acted on is restored, and only once.
/// - Focus the user didn't touch is on the page, or still where it was once
///   the action had started. A click focuses no menu, so after one, closing
///   the language picker gives focus back to whatever had it last, such as the
///   app bar's Back, and that isn't the user's choice either.
/// - The same order holds whenever a row goes while its menu has focus, for
///   whatever reason: a read can take it, as when a link was settled elsewhere.
/// - The selected filter takes focus only when no menu can: no row is listed,
///   or the user may not change anything. A row that is listed and not built
///   leaves focus alone. The page keeps the rows its footer covers built (see
///   [BgePage.footer]), so that is a row the user has scrolled well away from.
/// - The page stays too. What takes focus is brought into view, as Tab does, for
///   a user who can see focus, unless they moved the page on during the action.
///
/// Show more stays enabled while its page loads, and the bloc drops a press made
/// meanwhile, because a disabled button gives up keyboard focus (#607).
///
/// ## Reading it
///
/// A row's words read as one node, and its menu is a button of its own, named
/// for the row by its value and how that is spelled, since a value can be listed
/// once per format. What is loading, what failed and an empty list are each a live
/// region, so assistive tech says them as they appear. A status is an icon and
/// words, never color alone.
class LanguageLinkWorklist extends StatefulWidget {
  const LanguageLinkWorklist({required this.remote, super.key});

  static const Key linkKey = Key('language_link_worklist.link');
  static const Key ignoreKey = Key('language_link_worklist.ignore');
  static const Key acceptKey = Key('language_link_worklist.accept');
  static const Key moreKey = Key('language_link_worklist.more');
  static const Key outcomeKey = Key('language_link_worklist.outcome');
  static const Key emptyKey = Key('language_link_worklist.empty');
  static const Key errorKey = Key('language_link_worklist.error');

  /// One filter's chip.
  static Key filterKey(LanguageLinkFilter filter) =>
      Key('language_link_worklist.filter_${filter.name}');

  /// Per-row key: `language_link_worklist.row_<id>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by the
  /// row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String id) => Key('language_link_worklist.row_$id');

  /// Per-row menu button key: `language_link_worklist.menu_<id>`.
  static Key menuKey(String id) => Key('language_link_worklist.menu_$id');

  final DataGatewayRemoteDataSource remote;

  @override
  State<LanguageLinkWorklist> createState() => _LanguageLinkWorklistState();
}

class _LanguageLinkWorklistState extends State<LanguageLinkWorklist> {
  /// The node of the [Focus] around each row's menu, by link id, for as long as
  /// the row is listed.
  ///
  /// `PopupMenuButton` takes no focus node of its own, so this is the handle on
  /// a row's menu. It can't take focus itself: focus goes to the button inside.
  final Map<String, FocusNode> _menus = {};

  /// Each filter chip's node.
  final Map<LanguageLinkFilter, FocusNode> _chips = {
    for (final filter in LanguageLinkFilter.values)
      filter: FocusNode(debugLabel: 'language link filter ${filter.name}'),
  };

  /// The row the user last asked an action on, until that action ends.
  _ActedOn? _actedOn;

  /// The rows last shown, for where a row that goes was.
  List<LanguageLink> _listed = const [];

  /// The filter [_listed] is under.
  late LanguageLinkFilter _listedUnder;

  double? get _pageOffset => Scrollable.maybeOf(context)?.position.pixels;

  @override
  void initState() {
    super.initState();
    final state = context.read<LanguageLinkListBloc>().state;
    _listed = _linksOf(state);
    _listedUnder = state.filter;
  }

  static List<LanguageLink> _linksOf(LanguageLinkListState state) =>
      state is LanguageLinkListReady ? state.links : const [];

  FocusNode _menuNode(String id) => _menus.putIfAbsent(
    id,
    () =>
        FocusNode(debugLabel: 'language link menu $id', canRequestFocus: false),
  );

  Future<void> _act(LanguageLink link, LanguageLinkAction action) async {
    // Read before the picker opens: the page can move on while it is up, and
    // this bloc closes with the page.
    final bloc = context.read<LanguageLinkListBloc>();
    String? tagId;
    if (action == LanguageLinkAction.link) {
      final tag = await showLanguageTagPicker(
        context,
        remote: widget.remote,
        value: _nameOf(DataGatewayLocalizations.of(context), link),
      );
      if (tag == null || bloc.isClosed) return;
      tagId = tag.id;
    }
    _actedOn = _ActedOn(link.id);
    bloc.add(LanguageLinkListActionRequested(action, link.id, tagId: tagId));
  }

  /// Runs on every state, before the frame that builds it.
  void _onState(BuildContext context, LanguageLinkListState state) {
    final links = _linksOf(state);
    _followFocusedMenu(state, links);
    _listed = links;
    _listedUnder = state.filter;
    _forgetRowsGone(links);

    if (state is! LanguageLinkListReady) {
      // The rows came down, or the filter changed, so there is no place to
      // come back to.
      _actedOn = null;
      return;
    }
    final actedOn = _actedOn;
    if (actedOn == null) return;
    if (state.busy.contains(actedOn.id)) {
      final place = state.links.indexWhere((link) => link.id == actedOn.id);
      if (place != -1) actedOn.place = place;
      if (!actedOn.running) {
        actedOn.running = true;
        _letGoOfMenu(actedOn.id);
        // After the frame, because taking the last outcome's banner down can
        // move the page, and that isn't the user moving it. Focus has settled
        // by then too, on the page or wherever the picker gave it back.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          actedOn.pageAt = _pageOffset;
          actedOn.focusAt = FocusManager.instance.primaryFocus;
        });
      }
    } else if (actedOn.running) {
      _actedOn = null;
      final pageStayed =
          actedOn.pageAt == null || actedOn.pageAt == _pageOffset;
      _moveFocus(
        actedOn.id,
        actedOn.place,
        state.filter,
        inView: pageStayed,
        untouched: actedOn.focusAt,
      );
    }
  }

  /// When a menu with focus is about to go, because its row is leaving or the
  /// user may not change anything now, takes focus where it would go after an
  /// action on that row.
  ///
  /// Left to go with the menu, focus would land on whatever had it before. A
  /// read can do this at any time, as when a link was settled elsewhere, which
  /// is what the banner for a conflict says may have happened.
  void _followFocusedMenu(
    LanguageLinkListState state,
    List<LanguageLink> links,
  ) {
    final place = _listed.indexWhere(
      (link) => _menus[link.id]?.hasFocus ?? false,
    );
    if (place == -1) return;
    final id = _listed[place].id;
    final menuStays =
        state is LanguageLinkListReady &&
        state.mayChange &&
        links.any((link) => link.id == id);
    if (menuStays) return;
    _letGoOfMenu(id);
    _moveFocus(id, place, _listedUnder, inView: true);
  }

  /// Puts focus where it goes once the row [id], which was at [place] under
  /// [filter], has an action behind it or has left.
  ///
  /// After the frame that builds the menu, and from the rows as they are by
  /// then: the read that follows an action can land before that frame, and take
  /// the row. A row's place means nothing under another filter.
  ///
  /// Focus still on [untouched] counts as free, as on the page does.
  void _moveFocus(
    String id,
    int place,
    LanguageLinkFilter filter, {
    required bool inView,
    FocusNode? untouched,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<LanguageLinkListBloc>().state;
      final menuToBeHad =
          state is LanguageLinkListReady &&
          state.mayChange &&
          state.filter == filter;
      final row = menuToBeHad ? _rowAfter(id, place, _linksOf(state)) : null;
      _giveFocusBack(
        row?.id,
        state.filter,
        inView: inView,
        untouched: untouched,
      );
    });
  }

  /// Disposes the nodes of rows no longer listed, after the frame that takes
  /// them down: a [Focus] holds its node until then.
  void _forgetRowsGone(List<LanguageLink> links) {
    final listed = {for (final link in links) link.id};
    final gone = [
      for (final id in _menus.keys)
        if (!listed.contains(id)) id,
    ];
    if (gone.isEmpty) return;
    final nodes = [for (final id in gone) _menus.remove(id)!];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in nodes) {
        node.dispose();
      }
    });
  }

  /// Moves focus off the row's menu to the page, as it gives way to a spinner.
  void _letGoOfMenu(String id) {
    final menu = _menus[id];
    if (menu != null && menu.hasFocus) {
      menu.enclosingScope?.requestScopeFocus();
    }
  }

  /// The row whose menu takes focus after the row [id], which was at [place]:
  /// itself while it is in [links], the row now in its place, or the one before
  /// it. Null with no rows.
  LanguageLink? _rowAfter(String id, int place, List<LanguageLink> links) =>
      links.where((link) => link.id == id).firstOrNull ??
      (place < links.length ? links[place] : links.lastOrNull);

  /// Puts focus on the menu of the row [rowId], or with no row to take it, on
  /// the chip of [filter]. A row that is listed and not built takes nothing:
  /// the page has moved on from it, and the chip would pull it back.
  ///
  /// With [inView] it also brings that control into view, as Tab does, since
  /// the footer arriving can cover it. Not for a touch, which shows no focus,
  /// and would only have the page taken from it.
  void _giveFocusBack(
    String? rowId,
    LanguageLinkFilter filter, {
    required bool inView,
    FocusNode? untouched,
  }) {
    final focused = FocusManager.instance.primaryFocus;
    if (!_focusIsFree() && (untouched == null || focused != untouched)) return;
    final target = rowId == null
        ? _chips[filter]
        : _menus[rowId]?.descendants
              .where((node) => node.canRequestFocus)
              .firstOrNull;
    final control = target?.context;
    // A node keeps its context after its widget is gone.
    if (control == null || !control.mounted) return;
    target?.requestFocus();
    if (inView &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      control.findRenderObject()?.showOnScreen();
    }
  }

  /// Whether keyboard focus is on no control: on nothing, on the page holding
  /// this worklist, or on a scope that page sits inside. A scope anywhere else
  /// belongs to another route, such as a menu or a dialog that has just opened,
  /// and isn't this worklist's to take focus from.
  bool _focusIsFree() {
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null) return true;
    if (focused is! FocusScopeNode) return false;
    final page = FocusScope.of(context, createDependency: false);
    return focused == page || page.ancestors.contains(focused);
  }

  @override
  void dispose() {
    for (final node in _menus.values) {
      node.dispose();
    }
    for (final node in _chips.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<LanguageLinkListBloc, LanguageLinkListState>(
        listener: _onState,
        builder: (context, state) => SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: _Head(
                selected: state.filter,
                // Under a refused read another filter would be refused too.
                chips: state is LanguageLinkListDenied ? null : _chips,
              ),
            ),
            ...switch (state) {
              LanguageLinkListLoading() => const [_LoadingSliver()],
              LanguageLinkListDenied() => const [_DeniedSliver()],
              // Found gone, the page is already asking whether the DataGateway
              // is: its answer takes the screen, and until then this offers
              // what a failed read does.
              LanguageLinkListFailed() ||
              LanguageLinkListGone() => const [_FailedSliver()],
              LanguageLinkListReady(
                :final filter,
                :final links,
                :final busy,
                :final mayChange,
                :final hasMore,
                :final loadingMore,
                :final moreFailed,
              ) =>
                [
                  BgeKeyedSliverList<LanguageLink>(
                    items: links,
                    keyOf: (link) => LanguageLinkWorklist.rowKey(link.id),
                    itemBuilder: (context, link) => _LinkRow(
                      link: link,
                      busy: busy.contains(link.id),
                      menuFocus: mayChange ? _menuNode(link.id) : null,
                      onAction: (action) => unawaited(_act(link, action)),
                    ),
                  ),
                  // A whole page worked through leaves no rows with more on the
                  // server, and then "nothing to review" wouldn't be true.
                  if (links.isEmpty && !hasMore) _EmptySliver(filter: filter),
                  if (hasMore)
                    SliverToBoxAdapter(
                      child: _MoreFooter(
                        loading: loadingMore,
                        failed: moreFailed,
                      ),
                    ),
                ],
            },
          ],
        ),
      );
}

/// The row the user asked an action on.
final class _ActedOn {
  _ActedOn(this.id);

  final String id;

  /// The row's place in the list while its action ran.
  int place = 0;

  /// The action has started: the row has been seen busy. Until then a state
  /// without it says nothing, and the bloc may yet drop the action.
  bool running = false;

  /// How far the page was scrolled once the action had started.
  double? pageAt;

  /// Where keyboard focus was once the action had started, after it moved off
  /// the menu.
  FocusNode? focusAt;
}

/// The section's heading and its filters. [chips] holds a node for each filter,
/// and null leaves the filters out.
class _Head extends StatelessWidget {
  const _Head({required this.selected, required this.chips});

  final LanguageLinkFilter selected;
  final Map<LanguageLinkFilter, FocusNode>? chips;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final chips = this.chips;

    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.dataGatewayWorklistHeading,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (chips != null) ...[
            const BgeGap.sm(),
            Wrap(
              spacing: tokens.spaceSm,
              runSpacing: tokens.spaceSm,
              children: [
                for (final filter in LanguageLinkFilter.values)
                  FilterChip(
                    key: LanguageLinkWorklist.filterKey(filter),
                    focusNode: chips[filter],
                    label: Text(_filterLabel(l10n, filter)),
                    selected: filter == selected,
                    onSelected: (_) => context.read<LanguageLinkListBloc>().add(
                      LanguageLinkListFilterChanged(filter),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One language link: its value, what the DataGateway supplied beside it, and
/// its status.
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.link,
    required this.busy,
    required this.menuFocus,
    required this.onAction,
  });

  final LanguageLink link;
  final bool busy;

  /// The node to hold the row's menu with. Null hides the menu: the user may
  /// not change anything.
  final FocusNode? menuFocus;
  final ValueChanged<LanguageLinkAction> onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final name = _nameOf(l10n, link);
    final format = _formatLabel(l10n, link.format);
    // The tag can name a script or a region the value can't, such as zh-Hant
    // beside zho.
    final supplied = {
      for (final words in [
        link.suppliedName,
        link.suppliedNativeName,
        link.suppliedIetfTag,
      ])
        if (words != null && words.isNotEmpty && words != link.value) words,
    }.join(' · ');
    final status = _statusOf(l10n, Theme.of(context).colorScheme, link);
    final menuFocus = this.menuFocus;

    // Content, not a control: with no onTap the tile is no focus stop, and its
    // words read as one node. The menu in `trailing` is a control of its own.
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(link.value),
      subtitle: format == null && supplied.isEmpty && status == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (format != null) Text(format),
                if (supplied.isNotEmpty) Text(supplied),
                if ((format != null || supplied.isNotEmpty) && status != null)
                  const BgeGap.xs(),
                if (status != null)
                  DataGatewayIconAndWords(
                    icon: status.icon,
                    color: status.color,
                    words: status.words,
                  ),
              ],
            ),
      trailing: busy
          // A node of its own in the menu's place, not more words in the row's.
          // In a slot the size of the menu's button, so the row's words keep
          // their room, wrap the same, and move nothing under a pointer.
          ? Semantics(
              container: true,
              label: l10n.dataGatewayBusy(name),
              child: ExcludeSemantics(
                child: SizedBox.square(
                  dimension: kMinInteractiveDimension,
                  child: Center(
                    child: SizedBox.square(
                      // The size of the menu button's icon it stands in for.
                      dimension: tokens.spaceLg,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
            )
          : menuFocus != null
          ? Focus(
              focusNode: menuFocus,
              child: PopupMenuButton<LanguageLinkAction>(
                key: LanguageLinkWorklist.menuKey(link.id),
                tooltip: l10n.dataGatewayLanguageLinkActions(name),
                onSelected: onAction,
                itemBuilder: (_) => [
                  for (final action in languageLinkActions(link.status))
                    PopupMenuItem(
                      key: _actionKey(action),
                      value: action,
                      child: Text(_actionLabel(l10n, action)),
                    ),
                ],
              ),
            )
          : null,
    );
  }
}

/// The end of the list: the next page's button, and its failure.
///
/// Enabled through its own page, and relabelled: see the worklist's doc.
class _MoreFooter extends StatelessWidget {
  const _MoreFooter({required this.loading, required this.failed});

  final bool loading;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return Padding(
      padding: EdgeInsets.only(top: BgeTokens.of(context).spaceMd),
      child: Column(
        children: [
          if (failed) ...[
            _Notice(
              icon: Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
              words: l10n.dataGatewayWorklistMoreFailed,
            ),
            const BgeGap.sm(),
          ],
          OutlinedButton(
            key: LanguageLinkWorklist.moreKey,
            onPressed: () => context.read<LanguageLinkListBloc>().add(
              const LanguageLinkListMoreRequested(),
            ),
            child: Semantics(
              liveRegion: loading,
              child: Text(
                loading
                    ? l10n.dataGatewayWorklistMoreLoading
                    : failed
                    ? l10n.dataGatewayRetry
                    : l10n.dataGatewayWorklistMore,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the last action on a language link answered (#457): its copy, its
/// tone and its Dismiss.
///
/// The DataGateway's page shows it in its footer, under the banner for its own
/// actions. The detail screen's doc says why a footer.
class LanguageLinkOutcomeBanner extends StatelessWidget {
  const LanguageLinkOutcomeBanner({required this.outcome, super.key});

  final LanguageLinkOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final value = _named(l10n, outcome.value, outcome.format);

    final (tone, message) = switch (outcome.kind) {
      LanguageLinkOutcomeKind.linked => (
        BgeBannerTone.success,
        l10n.dataGatewayLanguageLinkOutcomeLinked(value),
      ),
      LanguageLinkOutcomeKind.ignored => (
        BgeBannerTone.success,
        l10n.dataGatewayLanguageLinkOutcomeIgnored(value),
      ),
      LanguageLinkOutcomeKind.accepted => (
        BgeBannerTone.success,
        l10n.dataGatewayLanguageLinkOutcomeAccepted(value),
      ),
      LanguageLinkOutcomeKind.conflict => (
        BgeBannerTone.info,
        l10n.dataGatewayLanguageLinkOutcomeConflict(value),
      ),
      LanguageLinkOutcomeKind.unknownTag => (
        BgeBannerTone.error,
        l10n.dataGatewayLanguageLinkOutcomeUnknownTag,
      ),
      LanguageLinkOutcomeKind.refused => (
        BgeBannerTone.info,
        l10n.dataGatewayChangeRefused,
      ),
      LanguageLinkOutcomeKind.gone => (
        BgeBannerTone.info,
        l10n.dataGatewayLanguageLinkOutcomeGone(value),
      ),
      LanguageLinkOutcomeKind.noAnswer => (
        BgeBannerTone.error,
        l10n.dataGatewayLanguageLinkOutcomeNoAnswer(value),
      ),
    };

    return BgeInlineBanner(
      key: LanguageLinkWorklist.outcomeKey,
      tone: tone,
      message: message,
      action: TextButton(
        onPressed: () => context.read<LanguageLinkListBloc>().add(
          const LanguageLinkListOutcomeDismissed(),
        ),
        child: Text(l10n.dataGatewayDismiss),
      ),
    );
  }
}

/// The first page being read, with no rows to show meanwhile.
class _LoadingSliver extends StatelessWidget {
  const _LoadingSliver();

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Center(
      child: Semantics(
        liveRegion: true,
        label: DataGatewayLocalizations.of(context).dataGatewayWorklistLoading,
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}

/// A refused read: what it means, with nothing to act on.
class _DeniedSliver extends StatelessWidget {
  const _DeniedSliver();

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return SliverToBoxAdapter(
      child: _Notice(
        icon: Icons.lock_outline,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        title: l10n.dataGatewayDeniedTitle,
        words: l10n.dataGatewayDeniedBody,
      ),
    );
  }
}

/// A read that failed, and the button that tries it again.
class _FailedSliver extends StatelessWidget {
  const _FailedSliver();

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return SliverToBoxAdapter(
      child: Column(
        key: LanguageLinkWorklist.errorKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Notice(
            icon: Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
            words: l10n.dataGatewayWorklistFailed,
          ),
          const BgeGap.sm(),
          OutlinedButton(
            onPressed: () => context.read<LanguageLinkListBloc>().add(
              const LanguageLinkListLoadRequested(),
            ),
            child: Text(l10n.dataGatewayRetry),
          ),
        ],
      ),
    );
  }
}

/// Nothing under [filter], and nothing more to read.
class _EmptySliver extends StatelessWidget {
  const _EmptySliver({required this.filter});

  final LanguageLinkFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return SliverToBoxAdapter(
      child: MergeSemantics(
        key: LanguageLinkWorklist.emptyKey,
        child: Semantics(
          liveRegion: true,
          child: Text(switch (filter) {
            LanguageLinkFilter.waiting => l10n.dataGatewayWorklistEmptyWaiting,
            LanguageLinkFilter.ignored => l10n.dataGatewayWorklistEmptyIgnored,
            LanguageLinkFilter.resolved =>
              l10n.dataGatewayWorklistEmptyResolved,
          }),
        ),
      ),
    );
  }
}

/// A message about the list, as an icon and words and not color alone, in a
/// live region.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.words,
    this.title,
  });

  final IconData icon;
  final Color color;
  final String words;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final title = this.title;

    // The merge outside and the live region inside, so the flag and the words
    // land on one node.
    return MergeSemantics(
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const BgeGap.sm(axis: Axis.horizontal),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (title != null) Text(title, style: textTheme.titleSmall),
                  Text(
                    words,
                    style: textTheme.bodyMedium?.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a row's status says: an icon and words. Null for a status this client
/// doesn't know, which has nothing it can say.
({IconData icon, Color color, String words})? _statusOf(
  DataGatewayLocalizations l10n,
  ColorScheme scheme,
  LanguageLink link,
) {
  final tag = link.tag;

  return switch (link.status) {
    LanguageLinkStatus.pending => (
      icon: Icons.hourglass_empty,
      color: scheme.tertiary,
      words: l10n.dataGatewayLanguageLinkStatusPending,
    ),
    LanguageLinkStatus.unresolved => (
      icon: Icons.link_off,
      color: scheme.tertiary,
      words: l10n.dataGatewayLanguageLinkStatusUnresolved,
    ),
    LanguageLinkStatus.ignored => (
      icon: Icons.do_not_disturb_on_outlined,
      color: scheme.onSurfaceVariant,
      words: l10n.dataGatewayLanguageLinkStatusIgnored,
    ),
    LanguageLinkStatus.resolved when tag != null => (
      icon: Icons.link,
      color: scheme.primary,
      words: l10n.dataGatewayLanguageLinkStatusResolved(tag.name, tag.tag),
    ),
    LanguageLinkStatus.resolved || LanguageLinkStatus.unknown => null,
  };
}

/// What the words call [link]: see the worklist's doc.
String _nameOf(DataGatewayLocalizations l10n, LanguageLink link) =>
    _named(l10n, link.value, link.format);

String _named(
  DataGatewayLocalizations l10n,
  String value,
  LanguageCodeFormat format,
) => switch (_formatLabel(l10n, format)) {
  null => value,
  final label => l10n.dataGatewayLanguageLinkNamed(value, label),
};

/// How a value is spelled. Null for a format this client doesn't know, which
/// has nothing it can say.
String? _formatLabel(
  DataGatewayLocalizations l10n,
  LanguageCodeFormat format,
) => switch (format) {
  LanguageCodeFormat.iso6391 => l10n.dataGatewayLanguageCodeFormatIso6391,
  LanguageCodeFormat.iso6393 => l10n.dataGatewayLanguageCodeFormatIso6393,
  LanguageCodeFormat.ietfBcp47 => l10n.dataGatewayLanguageCodeFormatIetfBcp47,
  LanguageCodeFormat.languageName => l10n.dataGatewayLanguageCodeFormatName,
  LanguageCodeFormat.nativeName => l10n.dataGatewayLanguageCodeFormatNativeName,
  LanguageCodeFormat.unknown => null,
};

String _filterLabel(DataGatewayLocalizations l10n, LanguageLinkFilter filter) =>
    switch (filter) {
      LanguageLinkFilter.waiting => l10n.dataGatewayWorklistFilterWaiting,
      LanguageLinkFilter.ignored => l10n.dataGatewayWorklistFilterIgnored,
      LanguageLinkFilter.resolved => l10n.dataGatewayWorklistFilterResolved,
    };

String _actionLabel(DataGatewayLocalizations l10n, LanguageLinkAction action) =>
    switch (action) {
      LanguageLinkAction.link => l10n.dataGatewayLanguageLinkActionLink,
      LanguageLinkAction.ignore => l10n.dataGatewayLanguageLinkActionIgnore,
      LanguageLinkAction.accept => l10n.dataGatewayLanguageLinkActionAccept,
    };

Key _actionKey(LanguageLinkAction action) => switch (action) {
  LanguageLinkAction.link => LanguageLinkWorklist.linkKey,
  LanguageLinkAction.ignore => LanguageLinkWorklist.ignoreKey,
  LanguageLinkAction.accept => LanguageLinkWorklist.acceptKey,
};
