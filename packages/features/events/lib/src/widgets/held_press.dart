import 'package:flutter/widgets.dart';

/// The press of a button that opens a page, sends what the page answers, and
/// keeps focus through that send (#607): event detail's Add people (#510),
/// and the Games tab's Offer games (#516).
///
/// The page hands focus back to the button as it closes, just before what
/// it answered goes out, and a disabled Material button can't hold focus.
/// So from its press until its own action is over, the button is held: a
/// `BgeInertButton` that stays enabled, ignores presses and says it is in
/// progress, wherever it would otherwise be unavailable. Its own action is
/// the page being open, then what the press sent and whatever that starts,
/// as the State says through [heldActionOver]. A button made unavailable by
/// anything else, another control's write, a read it didn't cause, no
/// connection, is disabled, as any control is.
///
/// - **Held.** From the press ([holdPress]). A second press meanwhile does
///   nothing; the page it opened covers the button meanwhile.
/// - **Let go at once** when the page answers with nothing to send:
///   [holdPress]'s action completes false.
/// - **Let go once its action is over**, or once the button is available,
///   whichever is first. When the action completes true, something went
///   out, and the press is let go the first time the button is built
///   available ([heldInert]'s `available`), or built again by its parent
///   with [heldActionOver] true. By its parent, because what ends the
///   action reaches the button as a rebuilt widget. The State is built
///   again as the action completes, so a button already available then is
///   let go even where the action rebuilds nothing.
///
/// So once what the press sent has gone out, the button is never shown
/// available while it ignores presses: it is inert, saying so, or let go.
/// A [heldActionOver] that is over later than the button is available
/// changes nothing while it is available; it keeps the press only through
/// the time the button would otherwise be disabled, so that it reads as in
/// progress then rather than as disabled.
///
/// The State builds the button from [heldInert], and passes it the press
/// handler while it is available or inert.
mixin HeldPress<T extends StatefulWidget> on State<T> {
  bool _pressed = false;
  bool _sent = false;

  /// Whether what the held press sent, and what that started, is over, read
  /// from the button's widget as its parent builds it.
  bool get heldActionOver;

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Built after what the press sent went out, with it over, or over
    // before a frame showed it.
    if (_sent && heldActionOver) _letGo();
  }

  /// Whether the button is inert as it is built now, given whether it is
  /// [available], pressable were no press held, and whether it is
  /// [disabled] for a reason that holds even through its own action, such
  /// as no connection. Called from `build`; a press whose action went out
  /// is let go here once the button is available.
  bool heldInert({required bool available, bool disabled = false}) {
    if (_sent && available) _letGo();
    return _pressed && !available && !disabled;
  }

  void _letGo() {
    _pressed = false;
    _sent = false;
  }

  /// Holds the press while [action] opens its page and sends what it
  /// answers. [action] completes true when something was sent, and false
  /// when nothing was.
  Future<void> holdPress(Future<bool> Function() action) async {
    // One press at a time: the page is open, or what it sent is out.
    if (_pressed) return;
    _pressed = true;
    var sent = false;
    try {
      sent = await action();
    } finally {
      // Built again either way, so a button available as the action ends
      // lets the press go ([heldInert]) though its action rebuilt nothing.
      if (sent) {
        if (mounted) setState(() => _sent = true);
      } else if (mounted) {
        setState(() => _pressed = false);
      }
    }
  }
}
