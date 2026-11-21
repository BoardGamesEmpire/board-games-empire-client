import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Whether a mouse's or a trackpad's press came after the last key press,
/// anywhere in the app, which hides every focus ring: one flag for the app, as
/// a browser keeps one for the page to decide `:focus-visible` (#644, #758).
///
/// A mouse or a trackpad leaves the highlight mode as it was, which on a
/// desktop is the keyboard's, so the highlight mode alone would ring a control
/// a click focused. A flag per control isn't enough either: focus that lands
/// on a control the mouse never pressed, handed back as a dialog closes, given
/// to a control that autofocuses, or moved there in code, would still be
/// ringed. So every ring reads this one flag, and shows only while it is
/// false.
///
/// Fills don't read it: they follow the highlight mode alone, as Material's
/// do.
///
/// A ring [attach]es while it is built and [detach]es as it goes, and the
/// app's root attaches for the app's lifetime (`BgeFocusLease`), so in the
/// app the flag watches pointers and keys all the time, and records a press
/// on a page with no ring built. It watches only while something is
/// attached, and forgets the press once nothing is, so a test or a widget
/// tree with no ring and no root holds no handlers.
abstract final class BgePointerPressed {
  static final _notifier = ValueNotifier<bool>(false);

  /// How many holders are attached: rings, and the app root's lease.
  static int _rings = 0;

  /// The flag, for a ring to listen to.
  static ValueListenable<bool> get listenable => _notifier;

  /// Whether a mouse's or a trackpad's press came after the last key press.
  static bool get value => _notifier.value;

  /// Counts one more ring, and starts watching pointers and keys for the
  /// first.
  static void attach() {
    if (_rings++ > 0) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// Counts one ring fewer. After the last, stops watching and forgets the
  /// press, so the next ring built starts from the keyboard's side.
  static void detach() {
    assert(_rings > 0, 'BgePointerPressed.detach() without an attach().');
    if (--_rings > 0) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _notifier.value = false;
  }

  /// Only a mouse's or a trackpad's press. A touch or a stylus turns the
  /// highlight mode to touch, which hides the ring already, and a mouse's
  /// hover, wheel or trackpad scroll isn't a press.
  static void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    if (event.kind
        case PointerDeviceKind.touch ||
            PointerDeviceKind.stylus ||
            PointerDeviceKind.invertedStylus) {
      return;
    }
    _notifier.value = true;
  }

  /// The user is at the keyboard again. A shortcut held with Control, Alt or
  /// Meta isn't navigation, as a browser's `:focus-visible` has it. A held
  /// key's repeats count as presses, as a browser's repeated `keydown`s do:
  /// Tab held down through a click goes on moving focus.
  static bool _onKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed) {
      _notifier.value = false;
    }
    return false;
  }
}
