import 'package:flutter/widgets.dart';

/// A single actionable item in the home navigation menu (#129).
///
/// Presentation-agnostic: [HomeScreen] renders these into the navigation
/// drawer in declaration order — the same contribution shape as
/// `SettingsSection`, so future top-level sections (collection, games,
/// households list) slot in as extra entries without the screen learning
/// their internals.
///
/// [onSelected] receives [HomeScreen]'s own (State) [BuildContext] — stable
/// and rooted under the auth scope + router, so navigation (`context.push`)
/// and provider reads (`context.read<AuthBloc>()`) resolve. It is called
/// **synchronously** on selection: the drawer's close animation may still be
/// in flight when it runs, which is fine for push / dispatch actions. An
/// entry that must wait for the drawer to finish closing has to arrange that
/// itself — [HomeScreen] does not await the close.
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

  /// Invoked with [HomeScreen]'s State context, synchronously on selection
  /// (the drawer close animation may still be in flight).
  final void Function(BuildContext context) onSelected;

  /// Destructive/terminal actions (e.g. sign out) render apart from the
  /// navigational destinations, below a divider and in the error color.
  final bool isDestructive;
}
