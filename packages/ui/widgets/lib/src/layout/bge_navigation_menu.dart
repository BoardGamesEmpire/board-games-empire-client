import 'package:flutter/widgets.dart';

/// What a navigation shell tells the pages beneath it about its menu (#414).
///
/// A shell puts this above its pages. A `BgePage` on a route with nothing
/// beneath it reads it to swap its implied back arrow for a menu button that
/// calls [onOpen]; a page does not otherwise know the shell exists.
///
/// Nothing rebuilds a page when the menu goes away, because a shell that is
/// there is there for good; [updateShouldNotify] covers the two fields that
/// can change under it, [onOpen] and [offersPageButton].
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
