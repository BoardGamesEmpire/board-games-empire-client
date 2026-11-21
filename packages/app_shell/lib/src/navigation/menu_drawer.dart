import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/navigation/nav_destination.dart';
import 'package:app_shell/src/screens/home_menu_entry.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The navigation menu (#129, #414): a drawer with the app's destinations,
/// where no bar or rail shows them, then its menu entries.
///
/// Presentation-only, and it only reports a pick. [onDestination] and
/// [onEntry] are called on a tap; the drawer neither closes itself nor runs
/// an entry's `onSelected`. The navigation shell closes it, and runs the
/// pick once it has gone (#643), or at once for a destructive entry such as
/// sign out.
///
/// [destinations] are [NavigationDrawerDestination]s, with [selectedId]'s
/// the selected one, so that a screen reader's tab role and position are true.
/// Every entry is a plain tile with a button role: it launches a screen or
/// fires an action and returns, so it has no selected state to say (#763).
/// A destructive entry (sign out) keeps the error colour and sits apart,
/// below a divider.
///
/// [status], where given, sits under the header, before the destinations:
/// the session's sync status (#47).
///
/// With [onServers], the header is a button that reports a pick of the
/// server manager (#134), which the shell runs as it runs an entry's.
///
/// Accessibility: the drawer is keyboard-traversable and each control has its
/// label as its name. The no-active-server case is handled defensively by
/// omitting the header.
class MenuDrawer extends StatefulWidget {
  const MenuDrawer({
    required this.destinations,
    required this.selectedId,
    required this.entries,
    required this.activeServerName,
    required this.onDestination,
    required this.onEntry,
    this.status,
    this.onServers,
    super.key,
  });

  /// The destinations to list, in order. Empty while a bar or rail shows them.
  final List<NavDestination> destinations;

  /// The id of the current destination, or null when none of [destinations]
  /// is current.
  final String? selectedId;

  /// Menu entries in display order. Destructive entries (e.g. sign out)
  /// render apart, below the others.
  final List<HomeMenuEntry> entries;

  /// Active server's display name for the drawer header, or null when none
  /// is active (defensive: home is only reached post-auth).
  final String? activeServerName;

  /// Called with the destination that was tapped.
  final ValueChanged<NavDestination> onDestination;

  /// Called with the entry that was tapped.
  final ValueChanged<HomeMenuEntry> onEntry;

  /// A line under the header, such as the session's sync status (#47), or
  /// null for none, which leaves no gap. It is not a destination or an
  /// entry, so the drawer neither selects it nor reports a pick of it.
  final Widget? status;

  /// Called when the header, which names the active server, is tapped, to
  /// open the server manager (#134). Null where there is none, as on the
  /// web: the header is then plain text.
  final VoidCallback? onServers;

  /// Key on the [NavigationDrawer], for tests.
  static const Key drawerKey = Key('home_navigation_drawer');

  /// Per-control key, for a destination as for an entry:
  /// `home_menu_entry_<id>`.
  static Key entryKey(String id) => Key('home_menu_entry_$id');

  @override
  State<MenuDrawer> createState() => _MenuDrawerState();
}

class _MenuDrawerState extends State<MenuDrawer> {
  @override
  void didUpdateWidget(MenuDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _keepDrawerFocus(oldWidget);
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
  void _keepDrawerFocus(MenuDrawer previous) {
    final before = _displayed(previous);
    final after = _displayed(widget);
    if (listEquals(before, after)) return;

    final focused = FocusManager.instance.primaryFocus;
    final scope = focused?.enclosingScope;
    if (focused == null || scope == null) return;
    final had = _entryOf(focused, before.map((e) => e.id));
    if (had == null) return;

    final hadGroup = before.firstWhere((e) => e.id == had).group;
    final group = [
      for (final e in before)
        if (e.group == hadGroup) e.id,
    ];
    final remaining = {for (final e in after) e.id};
    final at = group.indexOf(had);
    final target = remaining.contains(had)
        ? had
        : [
            ...group.skip(at + 1),
            ...group.take(at).toList().reversed,
          ].where(remaining.contains).firstOrNull;
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

  /// The ids of [drawer]'s controls in the order it shows them, each with its
  /// group: destinations, then entries, then destructive entries.
  static List<({String id, int group})> _displayed(MenuDrawer drawer) => [
    for (final destination in drawer.destinations)
      (id: destination.id, group: 0),
    for (final entry in drawer.entries)
      if (!entry.isDestructive) (id: entry.id, group: 1),
    for (final entry in drawer.entries)
      if (entry.isDestructive) (id: entry.id, group: 2),
  ];

  /// The id, of [ids], of the control [node] is in, or null for none.
  static String? _entryOf(FocusNode node, Iterable<String> ids) {
    final keys = {for (final id in ids) MenuDrawer.entryKey(id): id};
    String? found;
    node.context?.visitAncestorElements((element) {
      found = keys[element.widget.key];
      return found == null;
    });
    return found;
  }

  /// The key an entry's tile has among the drawer's children. The tile's
  /// ring keeps the row's focus node, so when an entry above goes, the
  /// children match by entry rather than by place, and each ring stays with
  /// its own entry.
  static Key _tileKey(HomeMenuEntry entry) => ValueKey('tile.${entry.id}');

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    final destinations = widget.destinations;
    final entries = widget.entries
        .where((e) => !e.isDestructive)
        .toList(growable: false);
    final actions = widget.entries
        .where((e) => e.isDestructive)
        .toList(growable: false);
    final selected = destinations.indexWhere((d) => d.id == widget.selectedId);

    // spaceLg (24) = the drawer's content inset: `tilePadding` (spaceSm) plus
    // the 16 gutter inside each destination. See `tilePadding` below;
    // `menu_drawer_test.dart` pins it.
    Widget divider() => Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spaceLg,
        vertical: tokens.spaceSm,
      ),
      child: const Divider(),
    );

    // Opening the drawer opens a route, and a screen reader says its name.
    // Flutter's `Drawer` names it with `drawerLabel` on Android, Fuchsia,
    // Linux and Windows, but on iOS and macOS only with a `semanticLabel`,
    // which `NavigationDrawer` never passes. A label round the drawer lands
    // on its route's node, so it is named there too, in the same words
    // (#50). Elsewhere it would be read twice.
    return Semantics(
      label: switch (defaultTargetPlatform) {
        TargetPlatform.iOS ||
        TargetPlatform.macOS => MaterialLocalizations.of(context).drawerLabel,
        _ => null,
      },
      child: NavigationDrawer(
        key: MenuDrawer.drawerKey,
        selectedIndex: selected < 0 ? null : selected,
        // Set explicitly, because it is load-bearing for alignment and
        // Flutter's default is an untokenized 12.
        //
        // A destination's content starts at `tilePadding + 16` — the 16 is a
        // fixed gutter inside NavigationDrawerDestination that is not
        // configurable. So the header, the divider, and the entry tiles
        // (whose ListTile adds its own 16) all have to be inset by this same
        // value to line up. Leaving the default 12 while the surrounding
        // insets moved onto the token scale is exactly how the groups
        // drifted 4dp apart.
        tilePadding: EdgeInsetsDirectional.symmetric(
          horizontal: tokens.spaceSm,
        ),
        onDestinationSelected: (index) =>
            widget.onDestination(destinations[index]),
        children: [
          _DrawerHeader(
            activeServerName: widget.activeServerName,
            serverLabel: l10n.homeActiveServerLabel,
            onServers: widget.onServers,
          ),
          _DrawerStatus(status: widget.status),
          for (final destination in destinations)
            NavigationDrawerDestination(
              key: MenuDrawer.entryKey(destination.id),
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
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
                child: Text(destination.label, overflow: TextOverflow.ellipsis),
              ),
            ),
          // One divider between two groups, never two in a row: with no
          // entries, the actions' own divider parts them from the
          // destinations.
          if (destinations.isNotEmpty && entries.isNotEmpty) divider(),
          for (final entry in entries)
            _MenuEntryTile(
              key: _tileKey(entry),
              entry: entry,
              onSelected: () => widget.onEntry(entry),
            ),
          if (actions.isNotEmpty) ...[
            divider(),
            for (final entry in actions)
              _MenuEntryTile(
                key: _tileKey(entry),
                entry: entry,
                onSelected: () => widget.onEntry(entry),
              ),
          ],
        ],
      ),
    );
  }
}

/// Drawer header showing the active server name, or nothing when none is
/// active (keeps the destination indices stable either way).
///
/// With [onServers] it is a button that opens the server manager (#134).
class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    required this.activeServerName,
    required this.serverLabel,
    required this.onServers,
  });

  final String? activeServerName;
  final String serverLabel;
  final VoidCallback? onServers;

  @override
  Widget build(BuildContext context) {
    final name = activeServerName;
    if (name == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final onServers = this.onServers;
    if (onServers != null) {
      return _serversButton(context, theme, name, onServers);
    }
    return Padding(
      // Start inset is spaceLg (24) to match the drawer's content inset —
      // `tilePadding` (spaceSm) plus the 16 gutter inside each destination.
      // Directional, as `tilePadding` is, so it matches in a right-to-left
      // language too.
      padding: EdgeInsetsDirectional.fromSTEB(
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

  /// The header as a button. Its ink is inset as an entry's is, and its
  /// content by the rest of the plain header's insets, so the name keeps
  /// its place and lines up with the destinations.
  ///
  /// A screen reader hears one button, named for the server and for what it
  /// opens: the drawn caption and name are left out, so the name isn't read
  /// a second time, and nothing reads as a header.
  Widget _serversButton(
    BuildContext context,
    ThemeData theme,
    String name,
    VoidCallback onServers,
  ) {
    final tokens = BgeTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spaceSm,
        tokens.spaceSm,
        tokens.spaceSm,
        0,
      ),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          label: ShellLocalizations.of(context).shellServersOpenLabel(name),
          child: InkWell(
            onTap: onServers,
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: tokens.minTapTarget),
                child: Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    tokens.spaceMd,
                    tokens.spaceSm,
                    tokens.spaceSm,
                    tokens.spaceSm,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              serverLabel,
                              style: theme.textTheme.labelSmall,
                            ),
                            const BgeGap.xs(),
                            Text(name, style: theme.textTheme.titleMedium),
                          ],
                        ),
                      ),
                      const BgeGap.sm(axis: Axis.horizontal),
                      const Icon(Icons.unfold_more),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [status] under the drawer header, at the header's start inset, or nothing
/// at all, gap included, without one (#47).
///
/// Always in the drawer's children, as the header is, so a status that
/// comes or goes changes nothing around it.
class _DrawerStatus extends StatelessWidget {
  const _DrawerStatus({required this.status});

  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    if (status == null) return const SizedBox.shrink();

    final tokens = BgeTokens.of(context);
    return Padding(
      // The header's start and end insets; the header's own bottom inset is
      // the gap above, and the same again parts it from the destinations.
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spaceLg,
        0,
        tokens.spaceMd,
        tokens.spaceSm,
      ),
      child: status,
    );
  }
}

/// A menu entry: a button that opens a screen or fires an action. Rendered as
/// a [ListTile] rather than a [NavigationDrawerDestination] so it stays out of
/// the destination selection/index model, which would read it as a tab (#763),
/// and so it can carry the error color when [HomeMenuEntry.isDestructive].
class _MenuEntryTile extends StatelessWidget {
  const _MenuEntryTile({
    required this.entry,
    required this.onSelected,
    super.key,
  });

  final HomeMenuEntry entry;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final color = entry.isDestructive
        ? Theme.of(context).colorScheme.error
        : null;
    return Padding(
      // spaceSm here + ListTile's own 16 content padding = the same 24 the
      // destinations sit at. Both halves have to move together.
      padding: EdgeInsets.symmetric(horizontal: BgeTokens.of(context).spaceSm),
      child: BgeRowFocusRing(
        builder: (context, row) => ListTile(
          key: MenuDrawer.entryKey(entry.id),
          focusNode: row.focusNode,
          onFocusChange: row.onFocusChange,
          focusColor: row.focusColor,
          leading: Icon(entry.icon, color: color),
          title: Text(
            entry.label,
            style: color == null ? null : TextStyle(color: color),
          ),
          onTap: row.onTap(onSelected),
        ),
      ),
    );
  }
}
