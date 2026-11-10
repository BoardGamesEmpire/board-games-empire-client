import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/screens/home_menu_entry.dart';
import 'package:app_shell/src/screens/home_sections.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The authenticated landing surface (#129): a real home with a
/// navigation drawer hosting the app's entry points, replacing the
/// temporary `HomePlaceholderScreen` (#37).
///
/// Presentation-only. [entries] are supplied by the composition layer
/// (`BgeApp`), which resolves per-feature l10n + actions and hands them in
/// — mirroring how `SettingsScreen` receives its sections. Navigational
/// entries render as [NavigationDrawerDestination]s; destructive ones
/// (sign out) render as a distinct action below a divider, in the error
/// color. No entry owns a persistent "selected" state yet — every current
/// entry is a launch-and-return flow or an action — so the drawer's
/// `selectedIndex` is null; when true co-equal sections land
/// (collection/games) they become selectable destinations.
///
/// The drawer is closed via the [Scaffold] state (through `_scaffoldKey`),
/// not `Navigator.pop` — a [Scaffold] drawer is not a route, so popping the
/// navigator would dismiss the page, not the drawer. Each entry's
/// `onSelected` then runs against this widget's context, which sits under
/// the auth scope + router, so `context.push` / `context.read` resolve.
///
/// Accessibility: the drawer is keyboard-traversable and each destination
/// carries its own control + label semantics; the app bar exposes the
/// platform-localized "open navigation menu" affordance. The no-active-
/// server case is handled defensively by omitting the header.
///
/// The page's content is the sections (#613), each built in its own feature
/// package and handed in through a slot. [HomeSections] decides their order
/// and which two pair up. With every slot null, which means a composition that
/// can offer none of them, the page shows a welcome line rather than nothing.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.entries,
    this.activeServerName,
    this.notice,
    this.upcomingEvents,
    this.stats,
    this.newestGames,
    this.somethingToPlay,
    super.key,
  });

  /// Menu entries in display order. Navigational entries render as drawer
  /// destinations; destructive entries (e.g. sign out) render apart.
  final List<HomeMenuEntry> entries;

  /// Active server's display name for the drawer header, or null when none
  /// is active (defensive — `/home` is only reached post-auth).
  final String? activeServerName;

  /// Shown above the page's content when given: the notice that leads to
  /// the changes that couldn't sync (#190), which draws nothing while none
  /// are stuck.
  final Widget? notice;

  /// The upcoming events section.
  final Widget? upcomingEvents;

  /// The caller's stats section.
  final Widget? stats;

  /// The shelf of newly added games.
  final Widget? newestGames;

  /// The "something to play" shelf.
  final Widget? somethingToPlay;

  /// Key on the [NavigationDrawer], for tests.
  static const Key drawerKey = Key('home_navigation_drawer');

  /// Key on the sections' column, which is absent with every slot null.
  static const Key sectionsKey = Key('home_sections');

  /// Per-entry tile key: `home_menu_entry_<id>`.
  static Key entryKey(String id) => Key('home_menu_entry_$id');

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  void _select(HomeMenuEntry entry) {
    // Close the drawer via the Scaffold (not the Navigator), then act
    // against this context — under the auth scope + router.
    _scaffoldKey.currentState?.closeDrawer();
    entry.onSelected(context);
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _keepDrawerFocus(oldWidget.entries);
  }

  /// Keeps keyboard focus in the drawer on a deliberate entry when the
  /// entries change under it (#456).
  ///
  /// The Admin entry goes whenever the session's access stops allowing read,
  /// and the session asks again on every resume and connectivity edge, so
  /// that can happen with the drawer open. The drawer rebuilds every entry
  /// below one that goes, because it matches them by position. Focus on any
  /// of those would fall to the drawer itself, which shows none, and the next
  /// Tab would start again from the top.
  ///
  /// So an entry the drawer rebuilt gets focus back. An entry that went hands
  /// it to the entry that takes its place, or with none below it to the one
  /// above. Each looks only in its own group, so a navigational entry never
  /// hands focus to a destructive action such as sign out. Focus anywhere
  /// else, including on an entry the change didn't rebuild, is left alone.
  ///
  /// Runs before the frame that changes the entries, while the entry still
  /// has focus.
  void _keepDrawerFocus(List<HomeMenuEntry> previous) {
    final before = _displayed(previous);
    final after = _displayed(widget.entries);
    if (listEquals(before, after)) return;

    final focused = FocusManager.instance.primaryFocus;
    final scope = focused?.enclosingScope;
    if (focused == null || scope == null) return;
    final had = _entryOf(focused, before);
    if (had == null) return;

    final destructive = {
      for (final entry in previous)
        if (entry.isDestructive) entry.id,
    };
    final group = [
      for (final id in before)
        if (destructive.contains(id) == destructive.contains(had)) id,
    ];
    final at = group.indexOf(had);
    final target = after.contains(had)
        ? had
        : [
            ...group.skip(at + 1),
            ...group.take(at).toList().reversed,
          ].where(after.contains).firstOrNull;
    if (target == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Still built: the change didn't take this entry's focus away.
      if (!mounted || (focused.context?.mounted ?? false)) return;
      scope.traversalDescendants
          .where((node) => _entryOf(node, [target]) == target)
          .firstOrNull
          ?.requestFocus();
    });
  }

  /// The ids of [entries] in the order the drawer shows them: destinations,
  /// then actions.
  static List<String> _displayed(List<HomeMenuEntry> entries) => [
    for (final entry in entries)
      if (!entry.isDestructive) entry.id,
    for (final entry in entries)
      if (entry.isDestructive) entry.id,
  ];

  /// The id, of [ids], of the entry [node] is in, or null for none.
  static String? _entryOf(FocusNode node, List<String> ids) {
    final keys = {for (final id in ids) HomeScreen.entryKey(id): id};
    String? found;
    node.context?.visitAncestorElements((element) {
      found = keys[element.widget.key];
      return found == null;
    });
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final hasSections =
        widget.upcomingEvents != null ||
        widget.stats != null ||
        widget.newestGames != null ||
        widget.somethingToPlay != null;

    final destinations = widget.entries
        .where((e) => !e.isDestructive)
        .toList(growable: false);
    final actions = widget.entries
        .where((e) => e.isDestructive)
        .toList(growable: false);

    return BgePage(
      scaffoldKey: _scaffoldKey,
      width: hasSections ? BgePageWidth.pane : BgePageWidth.form,
      centerVertically: !hasSections,
      title: Text(l10n.homeTitle),
      // Opening the drawer opens a route, and a screen reader says its name.
      // Flutter's `Drawer` names it with `drawerLabel` on Android, Fuchsia,
      // Linux and Windows, but on iOS and macOS only with a `semanticLabel`,
      // which `NavigationDrawer` never passes. A label round the drawer lands
      // on its route's node, so it is named there too, in the same words
      // (#50). Elsewhere it would be read twice.
      drawer: Semantics(
        label: switch (defaultTargetPlatform) {
          TargetPlatform.iOS ||
          TargetPlatform.macOS => MaterialLocalizations.of(context).drawerLabel,
          _ => null,
        },
        child: NavigationDrawer(
          key: HomeScreen.drawerKey,
          // Launcher semantics: entries push routes / fire actions and
          // return, so nothing is persistently selected yet.
          selectedIndex: null,
          // Set explicitly, because it is load-bearing for alignment and
          // Flutter's default is an untokenized 12.
          //
          // A destination's content starts at `tilePadding + 16` — the 16 is a
          // fixed gutter inside NavigationDrawerDestination that is not
          // configurable. So the header, the divider, and the action tiles
          // (whose ListTile adds its own 16) all have to be inset by this same
          // value to line up. Leaving the default 12 while the surrounding
          // insets moved onto the token scale is exactly how the two groups
          // drifted 4dp apart.
          tilePadding: EdgeInsetsDirectional.symmetric(
            horizontal: BgeTokens.of(context).spaceSm,
          ),
          onDestinationSelected: (index) => _select(destinations[index]),
          children: [
            _DrawerHeader(
              activeServerName: widget.activeServerName,
              serverLabel: l10n.homeActiveServerLabel,
            ),
            for (final entry in destinations)
              NavigationDrawerDestination(
                key: HomeScreen.entryKey(entry.id),
                icon: Icon(entry.icon),
                // Flexible, not a bare Text. `NavigationDrawerDestination`
                // places the label as a direct, non-flexed child of an internal
                // Row, so the Text's intrinsic width drives layout and
                // `overflow: ellipsis` alone never engages — it only applies
                // once the Text is width-constrained. Flexible supplies that
                // constraint from the one position that can.
                //
                // The hazard is real rather than theoretical: this label fit by
                // luck under the previous typeface and went 2.4px over when the
                // type scale gained letter-spacing. A longer localization would
                // have done the same. SemanticsNode.label keeps the full
                // string.
                label: Flexible(
                  child: Text(entry.label, overflow: TextOverflow.ellipsis),
                ),
              ),
            if (actions.isNotEmpty) ...[
              Padding(
                // spaceLg (24) = the drawer's content inset: `tilePadding`
                // (spaceSm) plus the 16 gutter inside each destination. See
                // `tilePadding` above; `home_screen_test.dart` pins it.
                padding: EdgeInsets.symmetric(
                  horizontal: BgeTokens.of(context).spaceLg,
                  vertical: BgeTokens.of(context).spaceSm,
                ),
                child: const Divider(),
              ),
              for (final entry in actions)
                _DrawerActionTile(
                  entry: entry,
                  onSelected: () => _select(entry),
                ),
            ],
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: hasSections
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.center,
        children: [
          ?widget.notice,
          if (hasSections)
            HomeSections(
              key: HomeScreen.sectionsKey,
              upcomingEvents: widget.upcomingEvents,
              stats: widget.stats,
              newestGames: widget.newestGames,
              somethingToPlay: widget.somethingToPlay,
            )
          else
            const _WelcomeLine(),
        ],
      ),
    );
  }
}

/// What the page shows with no sections to show.
class _WelcomeLine extends StatelessWidget {
  const _WelcomeLine();

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.dashboard_customize_outlined,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const BgeGap.md(),
        Semantics(
          header: true,
          child: Text(
            l10n.homeEmptyStateTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        const BgeGap.sm(),
        Text(
          l10n.homeEmptyStateBody,
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Drawer header showing the active server name, or nothing when none is
/// active (keeps the destination indices stable either way).
class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    required this.activeServerName,
    required this.serverLabel,
  });

  final String? activeServerName;
  final String serverLabel;

  @override
  Widget build(BuildContext context) {
    final name = activeServerName;
    if (name == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      // Start inset is spaceLg (24) to match the drawer's content inset —
      // `tilePadding` (spaceSm) plus the 16 gutter inside each destination.
      padding: EdgeInsets.fromLTRB(
        BgeTokens.of(context).spaceLg,
        BgeTokens.of(context).spaceMd,
        BgeTokens.of(context).spaceMd,
        BgeTokens.of(context).spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(serverLabel, style: theme.textTheme.labelSmall),
          const BgeGap.xs(),
          Semantics(
            header: true,
            child: Text(name, style: theme.textTheme.titleMedium),
          ),
        ],
      ),
    );
  }
}

/// A destructive/terminal drawer action (e.g. sign out). Rendered as a
/// [ListTile] rather than a [NavigationDrawerDestination] so it stays out
/// of the destination selection/index model and can carry the error color.
class _DrawerActionTile extends StatelessWidget {
  const _DrawerActionTile({required this.entry, required this.onSelected});

  final HomeMenuEntry entry;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Padding(
      // spaceSm here + ListTile's own 16 content padding = the same 24 the
      // destinations sit at. Both halves have to move together.
      padding: EdgeInsets.symmetric(horizontal: BgeTokens.of(context).spaceSm),
      child: ListTile(
        key: HomeScreen.entryKey(entry.id),
        leading: Icon(entry.icon, color: color),
        title: Text(entry.label, style: TextStyle(color: color)),
        onTap: onSelected,
      ),
    );
  }
}
