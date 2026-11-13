import 'package:flutter/material.dart';

/// What a navigation shell tells the pages beneath it about its menu (#414).
///
/// A shell puts this above its pages. A `BgePage` on a route with nothing
/// beneath it reads it to swap its implied back arrow for a [BgeMenuButton]
/// that calls [onOpen]; a page does not otherwise know the shell exists.
///
/// A page that reads it rebuilds when [onOpen] or [offersPageButton]
/// changes ([updateShouldNotify]), and when the menu comes or goes above it,
/// as for any inherited widget: a shell that steps aside for a while takes
/// the page's button with it, and brings it back on its return.
class BgeNavigationMenu extends InheritedWidget {
  /// Creates the menu hook for the pages in [child].
  const BgeNavigationMenu({
    required this.onOpen,
    required super.child,
    this.offersPageButton = true,
    super.key,
  });

  /// Opens the shell's menu.
  final VoidCallback onOpen;

  /// Whether a page shows the menu button.
  ///
  /// False while a rail carries the button, so a first route then shows no
  /// leading control at all, and no implied back arrow either.
  final bool offersPageButton;

  /// The menu above [context], or null when no shell is there.
  static BgeNavigationMenu? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BgeNavigationMenu>();

  @override
  bool updateShouldNotify(BgeNavigationMenu oldWidget) =>
      onOpen != oldWidget.onOpen ||
      offersPageButton != oldWidget.offersPageButton;
}

/// The button that opens a navigation shell's menu (#414): the menu icon,
/// named by Material's `openAppDrawerTooltip`.
///
/// The one control for both places the menu opens from, a first page's app
/// bar and a navigation rail's top, so a screen reader names it the same in
/// each.
class BgeMenuButton extends StatelessWidget {
  /// Creates a button that calls [onPressed] to open the menu.
  const BgeMenuButton({required this.onPressed, super.key});

  /// Opens the menu.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.menu),
    tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
    onPressed: onPressed,
  );
}
