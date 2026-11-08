import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether focus a pointer gave is to stay undrawn: true from a mouse's or a
/// trackpad's press until the next key press, as a browser's
/// `:focus-visible` is (#707). `BgePointerFocus` sets it and reads it.
///
/// The next key press ends it, unless Control, Alt or Meta is held: a
/// shortcut isn't navigation. Only while it is true does it listen for that
/// key press, and it stops when it is disposed, so no key handler is left
/// behind.
///
/// A control keeps one of its own, unless a `BgeFocusHandoff` above it
/// provides its item's through a [PointerFocusFlagScope]. Then the controls
/// in the item share it, and when the game changes form, the hand-off copies
/// it to the replacement before giving it focus (#769). For a hand-off that
/// waits on a pop, the scope keeps a flag of its own, so a key press on the
/// route above still ends it.
///
/// Not exported: the package's own focus widgets share it.
class PointerFocusFlag extends ValueNotifier<bool> {
  /// Creates a flag that is [value] to begin with.
  PointerFocusFlag([super.value = false]) {
    if (value) HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  set value(bool newValue) {
    if (newValue == value) return;
    if (newValue) {
      HardwareKeyboard.instance.addHandler(_onKey);
    } else {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    super.value = newValue;
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
    value = false;
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }
}

/// Provides an item's [PointerFocusFlag] to the controls inside it.
class PointerFocusFlagScope extends InheritedWidget {
  /// Provides [flag] to [child].
  const PointerFocusFlagScope({
    required this.flag,
    required super.child,
    super.key,
  });

  /// The item's flag.
  final PointerFocusFlag flag;

  /// The flag of the item [context] is in, if any, which [context] then
  /// depends on.
  static PointerFocusFlag? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PointerFocusFlagScope>()?.flag;

  @override
  bool updateShouldNotify(PointerFocusFlagScope oldWidget) =>
      !identical(flag, oldWidget.flag);
}
