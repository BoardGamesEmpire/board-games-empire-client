import 'package:flutter/material.dart';

import 'package:ui/src/connectivity/bge_connectivity_scope.dart';
import 'package:ui/src/connectivity/bge_online_only.dart';

/// An item of a [PopupMenuButton] that waits for a connection (#49): enabled
/// online, and offline disabled with [label] and the reason as its two lines.
///
/// A [PopupMenuItem] fixes `enabled` when the menu opens, while the reason
/// line reads the scope live, so a connection that changes under an open menu
/// would leave an enabled item saying it is unavailable, or a disabled one
/// with no reason. This entry builds its item from its own state, so both
/// follow the scope while the menu stays open.
///
/// The caller still guards `onSelected`: a press that lands as the connection
/// drops is not sent.
class BgeOnlineOnlyPopupMenuItem<T> extends PopupMenuEntry<T> {
  const BgeOnlineOnlyPopupMenuItem({
    required this.value,
    required this.label,
    super.key,
  });

  /// What the menu's `onSelected` receives.
  final T value;

  /// The item's words, already localized.
  final String label;

  @override
  double get height => kMinInteractiveDimension;

  @override
  bool represents(T? value) => value == this.value;

  @override
  State<BgeOnlineOnlyPopupMenuItem<T>> createState() =>
      _BgeOnlineOnlyPopupMenuItemState<T>();
}

class _BgeOnlineOnlyPopupMenuItemState<T>
    extends State<BgeOnlineOnlyPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) => PopupMenuItem<T>(
    value: widget.value,
    enabled: !BgeConnectivityScope.offlineOf(context),
    child: BgeOnlineOnlyLabel(widget.label),
  );
}
