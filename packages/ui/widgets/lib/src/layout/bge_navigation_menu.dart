import 'package:flutter/material.dart';

/// What a navigation shell tells the pages beneath it about its menu (#414).
///
/// A shell puts this above its pages. A `BgePage` on a route with nothing
/// beneath it reads it to swap its implied back arrow for a [BgeMenuButton]
/// that calls [onOpen]; a page does not otherwise know the shell exists.
///
/// Where the browser owns Back ([browserOwnsBack], #611), the page at a
/// section's top, a [BgeTopLevelRoute], shows the button too, however it
/// was reached, and every other page shows no leading control at all.
///
/// A page that reads it rebuilds when [onOpen], [offersPageButton] or
/// [browserOwnsBack] changes ([updateShouldNotify]), and when the menu comes
/// or goes above it, as for any inherited widget: a shell that steps aside
/// for a while takes the page's button with it, and brings it back on its
/// return.
class BgeNavigationMenu extends InheritedWidget {
  /// Creates the menu hook for the pages in [child].
  const BgeNavigationMenu({
    required this.onOpen,
    required super.child,
    this.offersPageButton = true,
    this.browserOwnsBack = false,
    super.key,
  });

  /// Opens the shell's menu.
  final VoidCallback onOpen;

  /// Whether a page shows the menu button.
  ///
  /// False while a rail carries the button, so a first route then shows no
  /// leading control at all, and no implied back arrow either.
  final bool offersPageButton;

  /// Whether the browser's own Back is the way back, as on the web (#611).
  ///
  /// An in-app back arrow would repeat it. So when true, a page at a
  /// section's top ([BgeTopLevelRoute]) shows the menu button as a first
  /// route does, even when it was pushed over another page, and every other
  /// page shows no leading control and no implied back arrow. A page's own
  /// leading control, or its `automaticallyImplyLeading: false`, is left as
  /// the page set it: a cancel in a flow is an action, not navigation.
  final bool browserOwnsBack;

  /// The menu above [context], or null when no shell is there.
  static BgeNavigationMenu? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BgeNavigationMenu>();

  @override
  bool updateShouldNotify(BgeNavigationMenu oldWidget) =>
      onOpen != oldWidget.onOpen ||
      offersPageButton != oldWidget.offersPageButton ||
      browserOwnsBack != oldWidget.browserOwnsBack;
}

/// Marks the page in [child] as the top of a section (#611): a destination's
/// own screen, or a screen the navigation menu opens, as against a page
/// under one.
///
/// A router puts it around the page of each route directly under its
/// navigation shell. It matters only where the browser owns Back
/// ([BgeNavigationMenu.browserOwnsBack]): there a `BgePage` beneath it shows
/// the menu button wherever it sits in the stack, since a screen the menu
/// pushed is as much a section as one it went to. Elsewhere it changes
/// nothing.
class BgeTopLevelRoute extends InheritedWidget {
  /// Marks [child] as the top of a section.
  const BgeTopLevelRoute({required super.child, super.key});

  /// Whether [context] is beneath a [BgeTopLevelRoute].
  static bool isAt(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BgeTopLevelRoute>() != null;

  /// A marker carries nothing that could change.
  @override
  bool updateShouldNotify(BgeTopLevelRoute oldWidget) => false;
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
