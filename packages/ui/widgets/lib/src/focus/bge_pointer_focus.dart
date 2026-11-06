import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps a control's focus feedback hidden while its focus is a pointer's, as
/// a browser's `:focus-visible` does (#707).
///
/// For a control that takes focus from a tap, so that a pop-up or a page it
/// opens hands focus back to it when it closes, as it does after a keyboard
/// activation. A touch or a stylus turns [FocusManager.highlightMode] to
/// touch, which hides focus feedback already. A mouse or a trackpad leaves it
/// as it was, which on a desktop is the keyboard's, so the control would be
/// ringed and tinted after a click, and again when focus came back to it, for
/// a user who never touched the keyboard.
///
/// The control calls [notePointerPress] with the kind of each press, before
/// the tap that gives it focus. From a mouse's or a trackpad's press until the
/// next key press [pointerFocus] is true, and the control hides its feedback:
/// a [BgeFocusRing] through `suppressed`, and an ink's tint through
/// [pointerFocusColor] as its `focusColor`. It isn't cleared when focus goes:
/// every press opens something, and the focus handed back would be drawn.
///
/// The next key press ends it, so a user who goes to the keyboard finds the
/// control. A shortcut held with Control, Alt or Meta isn't navigation, and
/// doesn't. A ring follows at once. An ink's tint doesn't: an [InkWell] keeps
/// a highlight at the strength it was first drawn with, so a tint drawn while
/// hidden stays hidden until the control's next focus.
///
/// Only while it is set does the state listen for that key press, and it
/// stops when it is disposed. A touch sets nothing: a phone, with no keyboard
/// to clear it, would keep a key handler for every control touched.
mixin BgePointerFocus<T extends StatefulWidget> on State<T> {
  bool _pointerFocus = false;

  /// Whether a mouse or a trackpad pressed the control since the last key
  /// press, which hides its focus feedback.
  bool get pointerFocus => _pointerFocus;

  /// The `focusColor` for the control's ink: the theme's tint with no
  /// strength while [pointerFocus], and null otherwise, for the ink's own.
  Color? get pointerFocusColor =>
      _pointerFocus ? Theme.of(context).focusColor.withValues(alpha: 0) : null;

  /// Notes a press of the control by a pointer of [kind]: a mouse's or a
  /// trackpad's sets [pointerFocus]. A null [kind], a press no pointer made,
  /// sets nothing.
  void notePointerPress(PointerDeviceKind? kind) {
    if (_pointerFocus) return;
    if (kind
        case null ||
            PointerDeviceKind.touch ||
            PointerDeviceKind.stylus ||
            PointerDeviceKind.invertedStylus) {
      return;
    }
    HardwareKeyboard.instance.addHandler(_onKey);
    setState(() => _pointerFocus = true);
  }

  /// The user is at the keyboard again, unless a shortcut is held.
  bool _onKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is! KeyDownEvent ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    keyboard.removeHandler(_onKey);
    setState(() => _pointerFocus = false);
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }
}
