import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:game_filters/src/game_filter_chip_label.dart';
import 'package:ui/ui.dart' show focusIsFree;
import 'package:ui_tokens/ui_tokens.dart';

/// One chip of [InUseChips].
typedef InUseChip<T> = ({
  /// Names the chip among the others, and keeps its focus across rebuilds.
  String id,

  /// The chip's key.
  Key key,

  /// What the chip says.
  String label,

  /// What a screen reader says for it, where that differs from [label].
  String? semanticsLabel,

  /// The remove button's tooltip, which is its name to a screen reader.
  String removeLabel,

  /// What [InUseChips.value] is once the chip is removed.
  T without,
});

/// A row of chips naming what narrows a list, each of which removes what it
/// names (#715, #516): a filter in use, a person chosen. Tapping a chip, or
/// its remove button, calls [onRemove] with it. With no chip it draws
/// nothing.
///
/// The caller holds what the chips are drawn from, [value], and rebuilds
/// this with the value a removal leaves.
///
/// ## Focus
///
/// A removed chip leaves the tree, and the user's place with it, so its
/// removal hands focus on, however the press arrived: from the keyboard, a
/// pointer, or a screen reader's activation, which moves no input focus.
/// Once the caller has rebuilt this with the value the chip's removal
/// leaves, its `without`, focus goes to the chip that took its place in the
/// order, else the one before it. With no chip left, [onEmptied] is called,
/// once, for the caller to put focus on a control of its own.
///
/// Focus moves only if it is free then: on nothing, on the page, or still
/// on the chip that left (`focusIsFree`). So a chip removed by a pointer
/// while keyboard focus sits on another control, another chip included,
/// moves nothing. A removal's hand-off waits for the next change of [value]
/// alone: one that is the value the chip's removal leaves settles it, and
/// any other drops it.
///
/// Keep it in the tree while it shows no chip, so that a hand-off to
/// [onEmptied] has a widget to run from.
class InUseChips<T> extends StatefulWidget {
  const InUseChips({
    required this.value,
    required this.chips,
    required this.onRemove,
    this.onEmptied,
    super.key,
  });

  /// What the chips are drawn from, compared by `==`.
  final T value;

  /// The chips, in order.
  final List<InUseChip<T>> chips;

  /// Called with the chip pressed, for the caller to remove what it names.
  final ValueChanged<InUseChip<T>> onRemove;

  /// Called once when the last chip is removed, however the press arrived,
  /// if focus is free afterwards (see Focus, above).
  final VoidCallback? onEmptied;

  @override
  State<InUseChips<T>> createState() => _InUseChipsState<T>();
}

/// One chip's focus: `area` holds the whole chip, its remove button too, and
/// `chip` is the chip's own, which a hand-off focuses.
typedef _ChipFocus = ({FocusNode area, FocusNode chip});

class _InUseChipsState<T> extends State<InUseChips<T>> {
  final _focus = <String, _ChipFocus>{};

  /// A chip's removal, waiting for the value it leaves, `without`: where
  /// the chip was among the chips, and the node that held focus if the
  /// chip, or its remove button, did.
  ({int index, FocusNode? node, T without})? _pending;

  @override
  void didUpdateWidget(InUseChips<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pending;
    if (pending == null || widget.value == oldWidget.value) return;
    _pending = null;
    if (widget.value != pending.without) return;
    // After the frame that builds the chips without it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(context, untouched: pending.node)) return;
      final ids = [for (final chip in widget.chips) chip.id];
      if (ids.isEmpty) {
        widget.onEmptied?.call();
        return;
      }
      _focus[ids[math.min(pending.index, ids.length - 1)]]?.chip.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final (:area, :chip) in _focus.values) {
      area.dispose();
      chip.dispose();
    }
    super.dispose();
  }

  void _remove(InUseChip<T> chip, int index) {
    // Armed by the press. Focus still on the chip that left counts as free.
    final focused = _focus[chip.id]?.area.hasFocus ?? false;
    _pending = (
      index: index,
      node: focused ? FocusManager.instance.primaryFocus : null,
      without: chip.without,
    );
    widget.onRemove(chip);
  }

  /// The focus nodes of the chips [ids] names, made for a chip as it comes
  /// and let go after the frame it leaves in.
  void _keepFocusOf(Set<String> ids) {
    for (final id in ids) {
      _focus.putIfAbsent(
        id,
        () => (
          area: FocusNode(
            debugLabel: 'InUseChips $id',
            canRequestFocus: false,
            skipTraversal: true,
          ),
          chip: FocusNode(debugLabel: 'InUseChips $id chip'),
        ),
      );
    }
    final gone = [
      for (final MapEntry(:key, :value) in _focus.entries)
        if (!ids.contains(key)) (key, value),
    ];
    if (gone.isEmpty) return;
    for (final (id, _) in gone) {
      _focus.remove(id);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (_, (:area, :chip)) in gone) {
        area.dispose();
        chip.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final chips = widget.chips;
    _keepFocusOf({for (final chip in chips) chip.id});
    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: tokens.spaceSm,
      runSpacing: tokens.spaceSm,
      children: [
        for (final (index, chip) in chips.indexed)
          Focus(
            focusNode: _focus[chip.id]!.area,
            includeSemantics: false,
            child: InputChip(
              key: chip.key,
              focusNode: _focus[chip.id]!.chip,
              label: GameFilterChipLabel(
                chip.label,
                semanticsLabel: chip.semanticsLabel,
              ),
              onPressed: () => _remove(chip, index),
              onDeleted: () => _remove(chip, index),
              deleteButtonTooltipMessage: chip.removeLabel,
            ),
          ),
      ],
    );
  }
}
