import 'package:flutter/material.dart';
import 'package:ui/src/banners/refresh_spinner.dart';
import 'package:ui/src/buttons/bge_inert_button.dart';

/// A list's refresh icon button, for the app bar's `BgePage.actions`, beside
/// a page's `onRefresh` gesture (#314, #717).
///
/// A mouse can't pull, and `RefreshIndicator` offers a screen reader no
/// action, so this is the route to a refresh by pointer, keyboard and screen
/// reader. It has the banner's retry rules: while [refreshing] it stays
/// enabled and focused, a press does nothing, and its label switches to
/// [inProgressLabel] (#607). It is a [BgeInertButton], so it is the same
/// semantics node at rest and busy.
///
/// A screen with no refresh seam leaves the button out; there is nothing to
/// disable it for.
///
/// The icon is `Icons.refresh`, not `Icons.sync`: the app already says "sync"
/// for the offline write queue (`BgeSyncBadge`), and this reads from the
/// server.
class BgeRefreshButton extends StatelessWidget {
  const BgeRefreshButton({
    required this.label,
    required this.inProgressLabel,
    required this.refreshing,
    required this.onPressed,
    this.buttonKey,
    super.key,
  });

  /// The button's name and tooltip at rest, such as "Refresh".
  final String label;

  /// The name and tooltip while a pass runs, such as "Refreshing…".
  final String inProgressLabel;

  /// A pass the user asked for is running.
  final bool refreshing;

  /// Starts a pass. Not called while [refreshing].
  final VoidCallback onPressed;

  /// Key on the icon button, so each screen's tests can address it, as
  /// `BgeRefreshBanner.retryKey` does the retry.
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final current = refreshing ? inProgressLabel : label;

    return BgeInertButton(
      inert: refreshing,
      label: current,
      onPressed: onPressed,
      builder: (context, focusNode, onPressed) => IconButton(
        key: buttonKey,
        focusNode: focusNode,
        onPressed: onPressed,
        tooltip: current,
        icon: refreshing
            ? const RefreshSpinner.icon()
            : const Icon(Icons.refresh),
      ),
    );
  }
}
