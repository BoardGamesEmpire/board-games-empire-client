import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ui/ui.dart';

/// The reason the shell gives a control that waits for a connection.
const onlineOnlyCopy = "Available when you're online";

/// A `MaterialApp.builder` that puts the app under a [BgeConnectivityScope]
/// following [offline], above the navigator as the shell hosts it, so menus
/// and dialogs read it too.
TransitionBuilder connectivityBuilder(
  ValueListenable<bool> offline, {
  TransitionBuilder? inner,
}) => (context, child) {
  final app = inner == null ? child! : inner(context, child);
  return ValueListenableBuilder<bool>(
    valueListenable: offline,
    child: app,
    builder: (context, isOffline, app) => BgeConnectivityScope(
      offline: isOffline,
      noticeShowing: isOffline,
      onlineOnlyReason: onlineOnlyCopy,
      child: app!,
    ),
  );
};
