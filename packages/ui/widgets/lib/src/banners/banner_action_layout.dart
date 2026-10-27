import 'dart:math' as math;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The two children of a [BannerActionLayout].
enum BannerActionSlot {
  /// The banner's icon and text.
  message,

  /// The banner's action, e.g. a retry button.
  action,
}

/// Lays out a banner's message and its action: the action beside the message
/// while the message keeps at least [minMessageWidth], and below it, at the
/// end edge, otherwise (#452).
///
/// The action is measured first, at its natural width up to the full width.
/// If what is left beside it, less [gap], is at least [minMessageWidth], the
/// action sits at the end edge of the row and the message takes all of the
/// rest. Otherwise the message takes the full width, and the action goes
/// [gap] below it, at the end edge: the right in left-to-right text, the left
/// in right-to-left. That is the Material banner's arrangement.
///
/// The rule measures the children as they are laid out, rather than switching
/// at a width tuned in advance. So it behaves the same under `flutter test`'s
/// font, whose glyphs are each one em wide, as under real fonts, which are
/// much narrower.
///
/// ## Why one render object
///
/// A `LayoutBuilder` that swapped a `Row` for a `Column` would give the same
/// two arrangements, but swapping the parent widget rebuilds the action's
/// element, and the button's state goes with it. The flip can come when the
/// user presses the button: "Try again" becoming "Refreshing…" can cross the
/// threshold. Here both arrangements place the same two children, so a flip
/// is only a relayout, and the button keeps its element and its state.
///
/// A call site that disables its button on press loses focus anyway: a
/// disabled `ButtonStyleButton` cannot hold focus (`canRequestFocus:
/// enabled`), and no layout can prevent that.
class BannerActionLayout
    extends SlottedMultiChildRenderObjectWidget<BannerActionSlot, RenderBox> {
  /// Creates a layout for a banner's [message] and [action].
  const BannerActionLayout({
    required this.message,
    required this.action,
    required this.gap,
    required this.minMessageWidth,
    super.key,
  });

  /// The banner's icon and text.
  final Widget message;

  /// The banner's action.
  final Widget action;

  /// The space between the message and the action, across in one arrangement
  /// and down in the other.
  final double gap;

  /// The narrowest [message] may get with the action beside it. Below this,
  /// the action moves under the message.
  final double minMessageWidth;

  @override
  Iterable<BannerActionSlot> get slots => BannerActionSlot.values;

  @override
  Widget childForSlot(BannerActionSlot slot) => switch (slot) {
    BannerActionSlot.message => message,
    BannerActionSlot.action => action,
  };

  @override
  RenderBannerActionLayout createRenderObject(BuildContext context) =>
      RenderBannerActionLayout(
        gap: gap,
        minMessageWidth: minMessageWidth,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBannerActionLayout renderObject,
  ) {
    renderObject
      ..gap = gap
      ..minMessageWidth = minMessageWidth
      ..textDirection = Directionality.of(context);
  }
}

/// Where [RenderBannerActionLayout] puts its children, and the size that
/// comes to.
typedef _Arrangement = ({
  Size size,
  BoxConstraints messageConstraints,
  Offset messageOffset,
  Offset actionOffset,
});

/// The render object behind [BannerActionLayout]. See there for the rule.
class RenderBannerActionLayout extends RenderBox
    with SlottedContainerRenderObjectMixin<BannerActionSlot, RenderBox> {
  /// Creates the render object for a [BannerActionLayout].
  RenderBannerActionLayout({
    required this._gap,
    required this._minMessageWidth,
    required this._textDirection,
  });

  /// See [BannerActionLayout.gap].
  double get gap => _gap;
  double _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  /// See [BannerActionLayout.minMessageWidth].
  double get minMessageWidth => _minMessageWidth;
  double _minMessageWidth;
  set minMessageWidth(double value) {
    if (_minMessageWidth == value) return;
    _minMessageWidth = value;
    markNeedsLayout();
  }

  /// Which edge is the end edge, where the action goes.
  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  // Both slots are required by the widget, so both are filled by the time
  // anything lays out, paints or hit-tests.
  RenderBox get _message => childForSlot(BannerActionSlot.message)!;
  RenderBox get _action => childForSlot(BannerActionSlot.action)!;

  /// In paint order, which is also semantics order: the message, then the
  /// action.
  @override
  Iterable<RenderBox> get children => [
    ?childForSlot(BannerActionSlot.message),
    ?childForSlot(BannerActionSlot.action),
  ];

  /// The message's width with the action beside it, in a row [width] wide,
  /// or null when that would leave it narrower than [minMessageWidth] and the
  /// action goes below.
  ///
  /// The tolerance is for the max intrinsic width, which is built by adding
  /// up the widths this subtracts. With fractional widths the round trip can
  /// land a hair under the threshold, and would stack the action at the one
  /// width that promises it sits beside.
  double? _messageWidthBeside(double width, double actionWidth) {
    final beside = width - actionWidth - gap;
    return beside >= minMessageWidth - precisionErrorTolerance ? beside : null;
  }

  /// The one place the arrangement is decided, shared by [performLayout],
  /// [computeDryLayout] and [computeDryBaseline] so that they cannot
  /// disagree. It only measures; [performLayout] places the children.
  _Arrangement _layout(BoxConstraints constraints, ChildLayouter layoutChild) {
    // Neither child gets a height limit. The banner is hosted in a page's
    // scroll view and is deliberately not capped in height (#228). Under a
    // parent that bounds the height, the size below is clamped to it, while
    // the children still lay out at their full height and paint past the
    // bottom edge, with no overflow warning.
    final width = constraints.maxWidth;
    final action = layoutChild(_action, BoxConstraints(maxWidth: width));
    final ltr = textDirection == TextDirection.ltr;

    final beside = _messageWidthBeside(width, action.width);
    if (beside != null) {
      final messageConstraints = BoxConstraints.tightFor(width: beside);
      final message = layoutChild(_message, messageConstraints);
      return (
        size: constraints.constrain(
          Size(width, math.max(message.height, action.height)),
        ),
        messageConstraints: messageConstraints,
        messageOffset: Offset(ltr ? 0 : width - beside, 0),
        actionOffset: Offset(ltr ? beside + gap : 0, 0),
      );
    }

    final messageConstraints = BoxConstraints.tightFor(width: width);
    final message = layoutChild(_message, messageConstraints);
    return (
      size: constraints.constrain(
        Size(width, message.height + gap + action.height),
      ),
      messageConstraints: messageConstraints,
      messageOffset: Offset.zero,
      actionOffset: Offset(
        ltr ? width - action.width : 0,
        message.height + gap,
      ),
    );
  }

  @override
  void performLayout() {
    final arrangement = _layout(constraints, ChildLayoutHelper.layoutChild);
    (_message.parentData! as BoxParentData).offset = arrangement.messageOffset;
    (_action.parentData! as BoxParentData).offset = arrangement.actionOffset;
    size = arrangement.size;
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _message.getMinIntrinsicWidth(double.infinity),
    _action.getMinIntrinsicWidth(double.infinity),
  );

  // The message's share is at least [minMessageWidth]. A message whose
  // natural width is below it would otherwise report a width at which the
  // action stacks, when a little more width puts it beside and makes the
  // banner shorter. That breaks the contract: past the max intrinsic width,
  // more width never reduces the height.
  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(
        _message.getMaxIntrinsicWidth(double.infinity),
        minMessageWidth,
      ) +
      gap +
      _action.getMaxIntrinsicWidth(double.infinity);

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(
    width,
    (child, width) => child.getMinIntrinsicHeight(width),
  );

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(
    width,
    (child, width) => child.getMaxIntrinsicHeight(width),
  );

  /// The height at [width], picking the arrangement the way [_layout] does,
  /// from the width the action would lay out at.
  ///
  /// Not its max intrinsic width. An action that wraps, like the invite
  /// outcome's pair of buttons, lays out narrower than that once it has to
  /// wrap. Measured by its max intrinsic width it stacks, where [_layout]
  /// puts it beside, and the height reported is the wrong arrangement's.
  double _intrinsicHeight(
    double width,
    double Function(RenderBox child, double width) heightOf,
  ) {
    final actionWidth = _action
        .getDryLayout(BoxConstraints(maxWidth: width))
        .width;
    final beside = _messageWidthBeside(width, actionWidth);
    if (beside != null) {
      return math.max(
        heightOf(_message, beside),
        heightOf(_action, actionWidth),
      );
    }
    return heightOf(_message, width) + gap + heightOf(_action, width);
  }

  // The banner's baseline is its message's: the message starts at the top in
  // both arrangements, and its first line is the banner's first line.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final offset = (_message.parentData! as BoxParentData).offset;
    final distance = _message.getDistanceToActualBaseline(baseline);
    return distance == null ? null : distance + offset.dy;
  }

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final arrangement = _layout(constraints, ChildLayoutHelper.dryLayoutChild);
    final distance = _message.getDryBaseline(
      arrangement.messageConstraints,
      baseline,
    );
    return distance == null ? null : distance + arrangement.messageOffset.dy;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in children) {
      final parentData = child.parentData! as BoxParentData;
      context.paintChild(child, parentData.offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // The reverse of paint order: the action is on top.
    for (final child in [_action, _message]) {
      final parentData = child.parentData! as BoxParentData;
      final hit = result.addWithPaintOffset(
        offset: parentData.offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('gap', gap))
      ..add(DoubleProperty('minMessageWidth', minMessageWidth))
      ..add(EnumProperty<TextDirection>('textDirection', textDirection));
  }
}
