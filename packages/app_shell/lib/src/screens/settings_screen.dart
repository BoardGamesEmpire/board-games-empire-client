import 'package:flutter/material.dart';

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
/// Accessibility: entries render in a single [ListView] in declaration
/// order (logical focus order), section headers are marked as semantic
/// headers, and each entry supplies its own control semantics.
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

  /// Key on the scrolling list, for tests.
  static const Key settingsListKey = Key('settings_list');

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final visibleSections = sections.where(_isVisible).toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: Text(i18n.settingsTitle)),
      body: SafeArea(
        child: ListView(
          key: settingsListKey,
          children: [
            for (final (index, section) in visibleSections.indexed)
              ..._buildSection(context, section, index),
          ],
        ),
      ),
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
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
