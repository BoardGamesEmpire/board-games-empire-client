import 'package:flutter/material.dart';

/// Which invites a list shows, as a "Show: …" button as wide as the pane
/// that opens a menu of [choices] (#487). The sent invites and a
/// household's invites (#475) both filter with it.
///
/// A button that opens a menu rather than a [DropdownMenu], whose
/// single-line field cut the chosen status short at 320dp and 2.0 text,
/// or a [SegmentedButton], whose segments break their words at that size
/// once there are three. This button's label wraps instead.
class InviteFilterMenu<T> extends StatefulWidget {
  const InviteFilterMenu({
    required this.buttonKey,
    required this.choices,
    required this.chosen,
    required this.choiceLabel,
    required this.buttonLabel,
    required this.onChosen,
    super.key,
  });

  /// The key on the button that opens the menu.
  final Key buttonKey;

  /// The filters, in the order the menu lists them.
  final List<T> choices;

  /// The filter the list is under.
  final T chosen;

  /// The words for a filter, in the menu and inside [buttonLabel].
  final String Function(T choice) choiceLabel;

  /// The button's words, given [chosen]'s.
  final String Function(String chosenLabel) buttonLabel;

  /// Called with a filter other than [chosen] when it is picked.
  final ValueChanged<T> onChosen;

  @override
  State<InviteFilterMenu<T>> createState() => _InviteFilterMenuState<T>();
}

class _InviteFilterMenuState<T> extends State<InviteFilterMenu<T>> {
  final FocusNode _button = FocusNode(debugLabel: 'InviteFilterMenu.button');

  @override
  void dispose() {
    _button.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => MenuAnchor(
      // The button's own node, as `BgeDropdownField` passes its field's
      // (#475): the menu gives focus back to it on Escape or a pick, and
      // the keyboard opens into the menu, not on past it to the rows.
      childFocusNode: _button,
      // As wide as the button that opens it. Left unconstrained, the menu
      // takes its widest entry's width and clips past the screen.
      crossAxisUnconstrained: false,
      style: MenuStyle(
        minimumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 0)),
        maximumSize: WidgetStatePropertyAll(
          Size(constraints.maxWidth, double.infinity),
        ),
      ),
      menuChildren: [
        for (final choice in widget.choices)
          MenuItemButton(
            // An empty icon on the others keeps their labels in line.
            leadingIcon: Icon(choice == widget.chosen ? Icons.check : null),
            overflowAxis: Axis.vertical,
            // Opening the menu puts focus on the filter chosen now, so the
            // arrows start from it.
            autofocus: choice == widget.chosen,
            // The chosen one only closes the menu: asking for it again
            // would read the list over, losing the pages shown.
            onPressed: () {
              if (choice != widget.chosen) widget.onChosen(choice);
            },
            // The check is only drawn, so the label says it is chosen.
            // Inside the item, where it merges into the item's own node;
            // around it, it would stand as a node of its own.
            child: Semantics(
              selected: choice == widget.chosen,
              child: Text(widget.choiceLabel(choice)),
            ),
          ),
      ],
      builder: (context, controller, _) => MergeSemantics(
        child: Semantics(
          expanded: controller.isOpen,
          child: OutlinedButton(
            key: widget.buttonKey,
            focusNode: _button,
            onPressed: controller.isOpen ? controller.close : controller.open,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.buttonLabel(widget.choiceLabel(widget.chosen)),
                  ),
                ),
                Icon(
                  controller.isOpen
                      ? Icons.arrow_drop_up
                      : Icons.arrow_drop_down,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
