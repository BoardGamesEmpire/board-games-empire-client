import 'package:flutter/widgets.dart';

import 'settings_entry.dart';
import 'settings_scope.dart';

/// A titled group of [SettingsEntry]s in a given [SettingsScope] (#120).
///
/// The screen decides visibility from [scope]: a [SettingsScope.perServer]
/// section is omitted when no server is active, and any section with no
/// [entries] is omitted entirely (no empty chrome).
class SettingsSection {
  const SettingsSection({
    required this.scope,
    required this.entries,
    this.titleBuilder,
  });

  /// Governs visibility and header treatment (see [SettingsScope]).
  final SettingsScope scope;

  /// The controls in this section, in display + focus order.
  final List<SettingsEntry> entries;

  /// Builds the section header, or null for no header.
  ///
  /// A builder (rather than a resolved string) so the title can come from
  /// [Localizations] read from the build context. For
  /// [SettingsScope.perServer] sections this is typically null — the
  /// screen supplies the active server's alias as the header instead.
  final String Function(BuildContext context)? titleBuilder;
}
