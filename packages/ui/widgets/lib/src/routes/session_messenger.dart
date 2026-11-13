import 'package:flutter/material.dart';

import 'package:ui/src/banners/bge_snack_bars.dart';

/// Says a screen's outcomes in SnackBars on the messenger above its route,
/// while the user session the screen was opened in is live (#464, #694).
///
/// A screen that saves and then leaves makes one when it makes its bloc,
/// asking the lease it took then, and says every bar through [say]: its
/// listener's, and the late one `closeWhenSettled` says once the screen has
/// gone. One guard serves every path, so no path can say a bar the others
/// would have kept back.
///
/// The session is asked even while the screen is mounted. The shell ends a
/// session in the same turn it routes away, and a leaving route stays mounted
/// through its exit transition, so a bar said then without asking would
/// reach the next account (#694).
///
/// `ui` depends on neither the lease nor bloc, so the lease comes in as a
/// `sessionIsLive` callback.
final class SessionMessenger {
  SessionMessenger({required this._sessionIsLive});

  final bool Function() _sessionIsLive;

  ScaffoldMessengerState? _messenger;

  /// Takes the messenger above [context]. Called from the screen's
  /// `didChangeDependencies`, while it is mounted: a save that settles after
  /// the screen has gone is said on this messenger, and `dispose` can't look
  /// it up.
  void attach(BuildContext context) {
    _messenger = ScaffoldMessenger.of(context);
  }

  /// Says [message] through `replaceSnackBar`. Nothing when there is no
  /// message, no messenger has been attached or it is no longer mounted, or
  /// the session has ended.
  void say(String? message) {
    final messenger = _messenger;
    if (message == null ||
        messenger == null ||
        !messenger.mounted ||
        !_sessionIsLive()) {
      return;
    }
    messenger.replaceSnackBar(message);
  }
}
