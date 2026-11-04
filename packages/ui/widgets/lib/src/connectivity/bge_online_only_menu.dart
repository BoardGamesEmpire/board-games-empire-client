import 'package:flutter/material.dart';

import 'bge_connectivity_scope.dart';

/// Owns the [MenuController] of a menu whose every item waits for a
/// connection (#49), and closes the menu when the connection drops while it
/// is open.
///
/// An item that goes disabled under the user's focus drops it to the menu's
/// own scope. Measured: with every item disabled, Tab cannot leave that
/// panel (Escape can). Closing the menu when the connection drops removes the
/// panel, so focus falls to the route and the next Tab reaches the page.
///
/// A menu opened while already offline is left open, so its items can be
/// read; Escape closes it.
class BgeOnlineOnlyMenu extends StatefulWidget {
  const BgeOnlineOnlyMenu({required this.builder, super.key});

  /// Builds the [MenuAnchor], given the controller to pass it.
  final Widget Function(BuildContext context, MenuController controller)
  builder;

  @override
  State<BgeOnlineOnlyMenu> createState() => _BgeOnlineOnlyMenuState();
}

class _BgeOnlineOnlyMenuState extends State<BgeOnlineOnlyMenu> {
  final MenuController _controller = MenuController();
  bool _offline = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final offline = BgeConnectivityScope.offlineOf(context);
    final dropped = offline && !_offline;
    _offline = offline;
    // Closing rebuilds the anchor, which cannot happen mid-build.
    if (dropped && _controller.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.isOpen) _controller.close();
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
