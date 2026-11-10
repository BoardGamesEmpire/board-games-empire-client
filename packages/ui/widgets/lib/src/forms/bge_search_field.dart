import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A text field that filters a list as the user types (#715, #516).
///
/// Not bound to `reactive_forms`, unlike `BgeTextField`: it filters, it does
/// not submit, so there is no control to keep in step and no error to show.
/// The caller filters in memory on every [onChanged], which is why nothing is
/// debounced here.
///
/// The widget owns its text and its focus. [initial] seeds the text once, in
/// `initState`; it is not a controlled value, and a rebuild with another
/// [initial] leaves what the user typed alone. A caller that wants a different
/// starting text gives the widget a new key.
///
/// ## Accessibility
///
/// - A visible label, always: [label] is the `InputDecoration`'s label, so it
///   stays on screen once the user types, and it is the field's one accessible
///   name. As on `BgeTextField`, no `Semantics` wrapper is added on top, which
///   would read the name twice.
/// - A label too long for the field at the user's text size is scaled down to
///   fit on one line, so it is never cut off. A label that fits keeps its full
///   size. Its accessible name is unaffected.
/// - The clear button exists only while there is text. It is an `IconButton`
///   named by [clearLabel] as its tooltip, which is also its accessible name,
///   and it is at least 48dp square (`BgeTokens.minTapTarget`).
/// - Pressing the clear button removes the control that had focus, so the press
///   puts focus on the field: a keyboard or screen-reader user stays where
///   they were typing rather than losing their place to the page.
class BgeSearchField extends StatefulWidget {
  /// Creates a search field that reports every edit to [onChanged].
  const BgeSearchField({
    required this.label,
    required this.clearLabel,
    required this.onChanged,
    this.initial = '',
    this.fieldKey,
    this.clearKey,
    super.key,
  });

  /// Visible label. Also the field's accessible name.
  final String label;

  /// The clear button's tooltip and accessible name.
  final String clearLabel;

  /// Called once per edit with the field's new text, and once with `''` when
  /// the clear button empties it.
  final ValueChanged<String> onChanged;

  /// The text the field starts with. Read once; see the class doc.
  final String initial;

  /// The key of the [TextField], for a caller's tests to find it by.
  final Key? fieldKey;

  /// The key of the clear [IconButton], for a caller's tests to find it by.
  final Key? clearKey;

  @override
  State<BgeSearchField> createState() => _BgeSearchFieldState();
}

class _BgeSearchFieldState extends State<BgeSearchField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _focus = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    // Before the next frame removes the button, so focus never has to be
    // found again: the control that holds it is about to leave the tree.
    _focus.requestFocus();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);

    // Rebuilt on every edit so the clear button follows the text.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => TextField(
        key: widget.fieldKey,
        controller: _controller,
        focusNode: _focus,
        textInputAction: TextInputAction.search,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          // Label, not hint-only. The border comes from the theme. A widget
          // rather than `labelText`, which the decoration ellipsises: this
          // scales the one line down to the room it has, so it is never cut
          // off, and a label that fits keeps its full size.
          label: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(widget.label),
          ),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: value.text.isEmpty
              ? null
              : SizedBox(
                  // Explicit rather than relying on the suffix slot's own
                  // minimum: a clear button that shrinks below 48dp is a
                  // WCAG 2.5.5 failure.
                  width: tokens.minTapTarget,
                  height: tokens.minTapTarget,
                  child: IconButton(
                    key: widget.clearKey,
                    icon: const Icon(Icons.clear),
                    tooltip: widget.clearLabel,
                    onPressed: _clear,
                  ),
                ),
        ),
      ),
    );
  }
}
