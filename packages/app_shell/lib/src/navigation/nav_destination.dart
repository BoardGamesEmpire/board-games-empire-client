import 'package:flutter/widgets.dart';

/// A top-level section of the app that the navigation shell lists (#414): a
/// tab of its bar or rail, or an entry of its menu where there is no bar.
///
/// Presentation-agnostic, as `HomeMenuEntry` is: the composition layer
/// resolves the label and the gate, and hands the finished value in.
@immutable
class NavDestination {
  const NavDestination({
    required this.id,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.location,
  });

  /// Stable identifier; also used to key the rendered control in tests.
  final String id;

  /// The icon while the destination isn't the current one.
  final IconData icon;

  /// The icon while the destination is the current one.
  final IconData selectedIcon;

  /// Already-localized label.
  final String label;

  /// The route the destination opens.
  final String location;

  /// Whether [path] is this destination's [location], or lies under it.
  bool contains(String path) =>
      path == location || path.startsWith('$location/');
}
