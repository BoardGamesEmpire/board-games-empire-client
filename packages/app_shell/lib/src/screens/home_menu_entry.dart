import 'package:flutter/widgets.dart';

/// A single actionable item in the shell's navigation menu (#129, #414).
///
/// Presentation-agnostic: `MenuDrawer` renders these into the navigation
/// drawer in declaration order, the same contribution shape as
/// `SettingsSection`, so a new screen the menu opens slots in as an entry
/// without the menu learning its internals. A top-level section is a
/// destination instead (`NavDestination`).
///
/// An entry opens a screen, at [location], or runs [onSelected]: one of the
/// two. The shell acts on a pick after the drawer has closed, except for a
/// destructive entry, which it runs at once.
@immutable
class HomeMenuEntry {
  const HomeMenuEntry({
    required this.id,
    required this.icon,
    required this.label,
    this.location,
    this.onSelected,
    this.isDestructive = false,
  }) : assert(
         (location == null) != (onSelected == null),
         'An entry opens a location or runs onSelected, not both.',
       );

  /// Stable identifier; also used to key the rendered tile in tests.
  final String id;

  /// Leading icon for the entry.
  final IconData icon;

  /// Already-localized label. The composition layer resolves per-feature
  /// l10n and passes the finished string in.
  final String label;

  /// The location of the screen the entry opens, which the shell pushes,
  /// or null where the entry runs [onSelected] instead.
  ///
  /// Picked while that screen is the page on top, the entry only closes the
  /// menu: the menu shows over every signed-in page (#414), and a second
  /// copy of the page would only add a step to Back.
  final String? location;

  /// The entry's action, where it opens no [location]. Invoked with the
  /// navigation shell's own [BuildContext], under the auth scope and the
  /// router, so provider reads (`context.read<AuthBloc>()`) resolve.
  final void Function(BuildContext context)? onSelected;

  /// Destructive/terminal actions (e.g. sign out) render apart from the
  /// other entries, below a divider and in the error color.
  final bool isDestructive;
}
