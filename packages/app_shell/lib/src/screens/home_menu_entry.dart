import 'package:flutter/widgets.dart';

/// A single actionable item in the shell's navigation menu (#129, #414).
///
/// Presentation-agnostic: `MenuDrawer` renders these into the navigation
/// drawer in declaration order, the same contribution shape as
/// `SettingsSection`, so future top-level sections slot in as extra entries
/// without the menu learning their internals.
///
/// [onSelected] receives the navigation shell's own [BuildContext], rooted
/// under the auth scope + router, so navigation (`context.push`) and provider
/// reads (`context.read<AuthBloc>()`) resolve. The shell runs it after the
/// drawer has closed, except for a destructive entry, which it runs at once.
@immutable
class HomeMenuEntry {
  const HomeMenuEntry({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelected,
    this.isDestructive = false,
  });

  /// Stable identifier; also used to key the rendered tile in tests.
  final String id;

  /// Leading icon for the entry.
  final IconData icon;

  /// Already-localized label. The composition layer resolves per-feature
  /// l10n and passes the finished string in.
  final String label;

  /// Invoked with the shell's context, once the drawer has closed. A
  /// destructive entry runs at once.
  final void Function(BuildContext context) onSelected;

  /// Destructive/terminal actions (e.g. sign out) render apart from the
  /// other entries, below a divider and in the error color.
  final bool isDestructive;
}
