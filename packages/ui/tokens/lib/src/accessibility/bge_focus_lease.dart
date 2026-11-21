import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/bge_pointer_pressed.dart';

/// What the app's root holds for its lifetime, so the focus cues the theme
/// draws without a widget of their own follow the pointer flag and the
/// highlight mode as those change (#758).
///
/// A chip's ring is its theme's side (`BgeChipFocus`, #761), and a
/// segment's focus fill and label are its theme's colours
/// (`BgeSegmentFocus`, #759). Each reads the flag or the highlight mode as
/// it resolves, but none has a lifecycle to listen with, and the control
/// resolves them again only when its own states change. Focus doesn't
/// change when a touch turns the highlight mode to touch, or a mouse press
/// sets the flag, so the control would keep what it showed. The lease
/// listens instead, and rebuilds the one control that can change, the
/// focused one:
///
/// - **A focused chip**, as the flag or the highlight mode changes: its
///   ring shows or hides.
/// - **A focused button**, any `ButtonStyleButton`, as the highlight mode
///   changes: a segment's fill and label show or go. Fills don't read the
///   flag, so a press rebuilds no button. Another button's ring has its
///   own listeners, and the rebuild changes nothing on it.
///
/// It also holds the pointer flag ([BgePointerPressed]), so the flag
/// records a press even on a page with no ring built.
abstract final class BgeFocusLease {
  /// How many holders are attached.
  static int _holders = 0;

  /// Holds the pointer flag, and starts rebuilding the focused chip or
  /// button as the flag or the highlight mode changes. The app's root calls
  /// it once, as it is built.
  static void attach() {
    BgePointerPressed.attach();
    if (_holders++ > 0) return;
    BgePointerPressed.listenable.addListener(_onPointerPressedChange);
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChange);
  }

  /// Lets go of what [attach] holds, as the app's root goes.
  static void detach() {
    assert(_holders > 0, 'BgeFocusLease.detach() without an attach().');
    if (--_holders == 0) {
      BgePointerPressed.listenable.removeListener(_onPointerPressedChange);
      FocusManager.instance.removeHighlightModeListener(
        _onHighlightModeChange,
      );
    }
    // After the listener goes: the last detach resets the flag, and the
    // tree may be locked then.
    BgePointerPressed.detach();
  }

  static void _onPointerPressedChange() => _rebuildFocused<RawChip>();

  static void _onHighlightModeChange(FocusHighlightMode _) {
    _rebuildFocused<RawChip>();
    _rebuildFocused<ButtonStyleButton>();
  }

  /// Rebuilds the nearest [T] round the primary focus, if there is one, so
  /// it resolves its theme's colours again.
  static void _rebuildFocused<T extends StatefulWidget>() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return;
    final state = context.findAncestorStateOfType<State<T>>();
    if (state == null || !state.mounted) return;
    (state.context as Element).markNeedsBuild();
  }
}
