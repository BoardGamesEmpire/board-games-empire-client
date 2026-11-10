import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:ui/src/focus/pointer_focus_flag.dart';

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
///
/// Inside a `BgeFocusHandoff` the state is the item's rather than the
/// control's, shared by the controls in it. When the game changes form, the
/// hand-off gives it to the replacement with the focus, so focus a click gave
/// stays undrawn in the new form too, until the next key press (#769). Inside
/// a control that passes its state on with [sharePointerFocus], the state is
/// that control's, the nearest of the two winning.
mixin BgePointerFocus<T extends StatefulWidget> on State<T> {
  /// The control's own state, where no item or enclosing control provides
  /// one.
  PointerFocusFlag? _own;

  /// The state the control follows: its item's, an enclosing control's, or
  /// its own.
  PointerFocusFlag? _flag;

  /// Whether a mouse or a trackpad pressed the control since the last key
  /// press, which hides its focus feedback.
  bool get pointerFocus => _flag?.value ?? false;

  /// The `focusColor` for the control's ink: the theme's tint with no
  /// strength while [pointerFocus], and null otherwise, for the ink's own.
  Color? get pointerFocusColor =>
      pointerFocus ? Theme.of(context).focusColor.withValues(alpha: 0) : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final flag =
        PointerFocusFlagScope.maybeOf(context) ?? (_own ??= PointerFocusFlag());
    if (identical(flag, _flag)) return;
    _flag?.removeListener(_onFlagChanged);
    _flag = flag..addListener(_onFlagChanged);
  }

  void _onFlagChanged() {
    if (mounted) setState(() {});
  }

  /// Gives the controls in [child] this control's state, so that a press on
  /// any of them hides the feedback of all of them until the next key press,
  /// as the controls of one `BgeFocusHandoff` item share theirs. For a
  /// control with a second one of its own, such as a cover's expansions badge
  /// (#711), where focus passes from one to the other.
  ///
  /// Call it from `build`: the state is found in [didChangeDependencies],
  /// which runs before the first build, and a call before then, such as from
  /// `initState`, fails.
  Widget sharePointerFocus(Widget child) =>
      PointerFocusFlagScope(flag: _flag!, child: child);

  /// Notes a press of the control by a pointer of [kind]: a mouse's or a
  /// trackpad's sets [pointerFocus]. A null [kind], a press no pointer made,
  /// sets nothing.
  void notePointerPress(PointerDeviceKind? kind) {
    if (kind
        case null ||
            PointerDeviceKind.touch ||
            PointerDeviceKind.stylus ||
            PointerDeviceKind.invertedStylus) {
      return;
    }
    _flag?.value = true;
  }

  @override
  void dispose() {
    _flag?.removeListener(_onFlagChanged);
    _own?.dispose();
    super.dispose();
  }
}
