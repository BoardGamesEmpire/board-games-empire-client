import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The home page's sections, in their fixed order (#613): upcoming events,
/// stats, then the two shelves. One column at every width (#669): the events
/// row moves side to side, and beside stats it would show a card and a half. A
/// null slot draws nothing and takes no gap, so each section ships on its own.
/// A slot whose section draws nothing, such as a blank stats card or a refused
/// shelf, takes no gap either (#674): the gap goes only between sections with
/// height, and comes or goes in the same frame as the section does.
///
/// Each slot is keyed, so that a slot filling or emptying can't hand its state
/// to the section after it, which the next position would otherwise give that
/// section's element. Events and stats come from different packages, and the
/// two shelves share a type, so without a key a section could take on its
/// neighbour's blocs, scroll offset and focus.
class HomeSections extends StatelessWidget {
  const HomeSections({
    this.upcomingEvents,
    this.stats,
    this.newestGames,
    this.somethingToPlay,
    super.key,
  });

  final Widget? upcomingEvents;
  final Widget? stats;
  final Widget? newestGames;
  final Widget? somethingToPlay;

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      ?_keyed(const ValueKey('home_upcoming_events'), upcomingEvents),
      ?_keyed(const ValueKey('home_stats'), stats),
      ?_keyed(const ValueKey('home_newest_games'), newestGames),
      ?_keyed(const ValueKey('home_something_to_play'), somethingToPlay),
    ];

    return _SectionColumn(
      gap: BgeTokens.of(context).spaceXl,
      children: sections,
    );
  }

  static Widget? _keyed(Key key, Widget? section) =>
      section == null ? null : KeyedSubtree(key: key, child: section);
}

/// The sections top to bottom at full width, with [gap] only between two that
/// have height (#674). A `Column` can't do this: it, and its `spacing`, put a
/// gap beside a child of no height too, and a section that draws nothing still
/// sits in its slot.
class _SectionColumn extends MultiChildRenderObjectWidget {
  const _SectionColumn({required this.gap, required super.children});

  final double gap;

  @override
  _RenderSectionColumn createRenderObject(BuildContext context) =>
      _RenderSectionColumn(gap: gap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSectionColumn renderObject,
  ) {
    renderObject.gap = gap;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('gap', gap));
  }
}

class _SectionParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderSectionColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SectionParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SectionParentData> {
  _RenderSectionColumn({required this._gap});

  double get gap => _gap;
  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SectionParentData) {
      child.parentData = _SectionParentData();
    }
  }

  /// Each section takes the column's width and as much height as it needs.
  static BoxConstraints _childConstraints(BoxConstraints constraints) {
    assert(constraints.hasBoundedWidth, 'The sections need a bounded width.');
    return BoxConstraints.tightFor(width: constraints.maxWidth);
  }

  /// Stacks the children, each sized by [childHeight], and returns the
  /// column's height. [onChild] is told each child's top, and returns false
  /// to stop the walk there.
  double _stack(
    double Function(RenderBox child) childHeight, [
    bool Function(RenderBox child, double top)? onChild,
  ]) {
    var y = 0.0;
    var drawn = false;
    var child = firstChild;
    while (child != null) {
      final height = childHeight(child);
      if (height > 0) {
        if (drawn) y += gap;
        drawn = true;
      }
      if (onChild?.call(child, y) == false) return y;
      y += height;
      child = childAfter(child);
    }
    return y;
  }

  @override
  void performLayout() {
    final childConstraints = _childConstraints(constraints);
    final height = _stack(
      (child) => ChildLayoutHelper.layoutChild(child, childConstraints).height,
      (child, top) {
        (child.parentData! as _SectionParentData).offset = Offset(0, top);
        return true;
      },
    );
    size = constraints.constrain(Size(constraints.maxWidth, height));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final childConstraints = _childConstraints(constraints);
    final height = _stack(
      (child) =>
          ChildLayoutHelper.dryLayoutChild(child, childConstraints).height,
    );
    return constraints.constrain(Size(constraints.maxWidth, height));
  }

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final childConstraints = _childConstraints(constraints);
    double? first;
    _stack(
      (child) =>
          ChildLayoutHelper.dryLayoutChild(child, childConstraints).height,
      (child, top) {
        final distance = child.getDryBaseline(childConstraints, baseline);
        if (distance == null) return true;
        first = top + distance;
        return false;
      },
    );
    return first;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _stack((child) => child.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _stack((child) => child.getMaxIntrinsicHeight(width));

  // The children are laid out with no height limit, so their widths are
  // asked the same way.
  @override
  double computeMinIntrinsicWidth(double height) =>
      _widest((child) => child.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _widest((child) => child.getMaxIntrinsicWidth(double.infinity));

  double _widest(double Function(RenderBox child) childWidth) {
    var widest = 0.0;
    var child = firstChild;
    while (child != null) {
      widest = math.max(widest, childWidth(child));
      child = childAfter(child);
    }
    return widest;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('gap', gap));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
