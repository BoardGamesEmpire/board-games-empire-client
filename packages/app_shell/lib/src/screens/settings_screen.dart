import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/shell_localizations.dart';
import '../settings/settings_scope.dart';
import '../settings/settings_section.dart';

/// The settings surface (#120): a scrollable, accessible list of
/// [SettingsSection]s.
///
/// Composition is supplied ([sections]) rather than hard-coded, so feature
/// entries can be contributed without the screen importing their
/// internals. Visibility rules:
/// - a [SettingsScope.perServer] section is omitted when
///   [activeServerAlias] is null (no active server), and otherwise
///   rendered under a header naming that alias;
/// - any section with no entries is omitted entirely.
///
/// Accessibility: entries render in a single [SliverList] in declaration
/// order (logical focus order), section headers are marked as semantic
/// headers, and each entry supplies its own control semantics.
///
/// Built on `BgePage.slivers` rather than the box constructor so the page
/// has one real viewport. A list nested inside a box scroll view has to be
/// shrink-wrapped and non-scrollable, which splits the collection semantics
/// across two nodes — the scrollable one loses its `scrollChildCount`, so a
/// screen reader stops announcing "item 3 of 9".
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.sections,
    this.activeServerAlias,
    super.key,
  });

  /// The composed sections, in display order.
  final List<SettingsSection> sections;

  /// Display name of the active server, or null when none is active.
  /// Gates and labels [SettingsScope.perServer] sections.
  final String? activeServerAlias;

  /// Key on the entry list, for tests. The list no longer scrolls itself —
  /// [BgePage] owns that — so this identifies the content column whose width
  /// the pane measure caps.
  static const Key settingsListKey = Key('settings_list');

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final visibleSections = sections.where(_isVisible).toList(growable: false);
    final rows = [
      for (final (index, section) in visibleSections.indexed)
        ..._buildSection(context, section, index),
    ];

    return BgePage.slivers(
      title: Text(i18n.settingsTitle),
      // A settings row is a label plus a trailing control, not prose, so it
      // takes the pane measure rather than the 480 reading measure a form
      // gets. A cap, so on a phone it does not bite.
      width: BgePageWidth.pane,
      // Zero, not the page default: a settings list is edge-to-edge, and
      // ListTile already carries its own 16dp inset. The default spaceLg
      // gutter would stop every row's divider, ripple and focus ring short
      // of the window edge, which is not how a Material list surface reads.
      padding: EdgeInsets.zero,
      // Slivers, so the page has one real viewport: a settings list is a
      // collection a screen reader navigates, and it has to keep its
      // `scrollChildCount` — "item 3 of 9" — which a list nested inside a
      // box scroll view loses.
      // The count a screen reader reads as "item 3 of 9". CustomScrollView
      // cannot infer it the way ListView(children:) does.
      semanticChildCount: rows.length,
      slivers: [SliverList.list(key: settingsListKey, children: rows)],
    );
  }

  bool _isVisible(SettingsSection section) {
    if (section.entries.isEmpty) return false;
    if (section.scope == SettingsScope.perServer && activeServerAlias == null) {
      return false;
    }
    return true;
  }

  List<Widget> _buildSection(
    BuildContext context,
    SettingsSection section,
    int index,
  ) {
    final header = switch (section.scope) {
      // Guaranteed non-null here: perServer sections with a null alias are
      // filtered out by [_isVisible].
      SettingsScope.perServer => activeServerAlias,
      SettingsScope.appLevel => section.titleBuilder?.call(context),
    };

    return [
      if (header != null)
        Padding(
          padding: EdgeInsets.fromLTRB(
            BgeTokens.of(context).spaceMd,
            BgeTokens.of(context).spaceMd,
            BgeTokens.of(context).spaceMd,
            BgeTokens.of(context).spaceXs,
          ),
          child: Semantics(
            header: true,
            child: Text(header, style: Theme.of(context).textTheme.titleSmall),
          ),
        ),
      // Namespaced by the section's position in the visible list: entries
      // flatten into one ListView, so an id only unique *within* a section
      // (SettingsEntry's contract) would otherwise collide across sections
      // (e.g. an app-level and a per-server 'notifications' entry).
      for (final entry in section.entries)
        KeyedSubtree(
          key: ValueKey('settings_entry_${index}_${entry.id}'),
          child: entry.build(context),
        ),
    ];
  }
}
