import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/shell_localizations.dart';
import 'home_menu_entry.dart';

/// The authenticated landing surface (#129): a real home with a
/// navigation drawer hosting the app's entry points, replacing the
/// temporary `HomePlaceholderScreen` (#37).
///
/// Presentation-only. [entries] are supplied by the composition layer
/// ([BgeApp]), which resolves per-feature l10n + actions and hands them in
/// — mirroring how `SettingsScreen` receives its sections. Navigational
/// entries render as [NavigationDrawerDestination]s; destructive ones
/// (sign out) render as a distinct action below a divider, in the error
/// color. No entry owns a persistent "selected" state yet — every current
/// entry is a launch-and-return flow or an action — so the drawer's
/// `selectedIndex` is null; when true co-equal sections land
/// (collection/games) they become selectable destinations.
///
/// The drawer is closed via the [Scaffold] state (through [_scaffoldKey]),
/// not `Navigator.pop` — a [Scaffold] drawer is not a route, so popping the
/// navigator would dismiss the page, not the drawer. Each entry's
/// `onSelected` then runs against this widget's context, which sits under
/// the auth scope + router, so `context.push` / `context.read` resolve.
///
/// Accessibility: the drawer is keyboard-traversable and each destination
/// carries its own control + label semantics; the app bar exposes the
/// platform-localized "open navigation menu" affordance. The no-active-
/// server case is handled defensively by omitting the header.
class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.entries, this.activeServerName, super.key});

  /// Menu entries in display order. Navigational entries render as drawer
  /// destinations; destructive entries (e.g. sign out) render apart.
  final List<HomeMenuEntry> entries;

  /// Active server's display name for the drawer header, or null when none
  /// is active (defensive — `/home` is only reached post-auth).
  final String? activeServerName;

  /// Key on the [NavigationDrawer], for tests.
  static const Key drawerKey = Key('home_navigation_drawer');

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
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final theme = Theme.of(context);

    final destinations = widget.entries
        .where((e) => !e.isDestructive)
        .toList(growable: false);
    final actions = widget.entries
        .where((e) => e.isDestructive)
        .toList(growable: false);

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(title: Text(l10n.homeTitle)),
      drawer: NavigationDrawer(
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
              // have done the same. SemanticsNode.label keeps the full string.
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
              _DrawerActionTile(entry: entry, onSelected: () => _select(entry)),
          ],
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: BgeTokens.of(context).contentMaxWidth,
            ),
            child: Padding(
              padding: EdgeInsets.all(BgeTokens.of(context).spaceLg),
              child: Column(
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
              ),
            ),
          ),
        ),
      ),
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
