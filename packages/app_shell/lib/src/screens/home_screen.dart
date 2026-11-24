import 'dart:math' as math;

import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/screens/home_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The authenticated landing surface (#129): a real home, replacing the
/// temporary placeholder screen (#37).
///
/// Presentation-only. The navigation menu is not the page's: the navigation
/// shell hosts it above every signed-in page (#414). The button that opens
/// it is the navigation rail's where the rail shows, at medium and up with
/// two or more destinations, and otherwise this page's, in its app bar.
///
/// The page's content is the sections (#613), each built in its own feature
/// package and handed in through a slot. [HomeSections] decides their order
/// and which two pair up. With every slot null, which means a composition that
/// can offer none of them, the page shows a welcome line rather than nothing.
/// With slots filled but every section drawing nothing, such as a refused
/// shelf beside nothing to play, the welcome line takes their place (#1107).
/// Whether a section draws is known only at layout, so that line sits at the
/// top of the sections' measure rather than centred, and goes in the same
/// frame a section starts drawing.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    this.notice,
    this.upcomingEvents,
    this.stats,
    this.newestGames,
    this.somethingToPlay,
    super.key,
  });

  /// Shown above the page's content when given: the notice that leads to
  /// the changes that couldn't sync (#190), which draws nothing while none
  /// are stuck.
  final Widget? notice;

  /// The upcoming events section.
  final Widget? upcomingEvents;

  /// The caller's stats section.
  final Widget? stats;

  /// The shelf of newly added games.
  final Widget? newestGames;

  /// The "something to play" shelf.
  final Widget? somethingToPlay;

  /// Key on the sections' column, which is absent with every slot null.
  static const Key sectionsKey = Key('home_sections');

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final hasSections =
        upcomingEvents != null ||
        stats != null ||
        newestGames != null ||
        somethingToPlay != null;

    return BgePage(
      width: hasSections ? BgePageWidth.pane : BgePageWidth.form,
      centerVertically: !hasSections,
      title: Text(l10n.homeTitle),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: hasSections
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.center,
        children: [
          ?notice,
          if (hasSections)
            _OrWhenBlank(
              fallback: const _WelcomeLine(),
              child: HomeSections(
                key: sectionsKey,
                upcomingEvents: upcomingEvents,
                stats: stats,
                newestGames: newestGames,
                somethingToPlay: somethingToPlay,
              ),
            )
          else
            const _WelcomeLine(),
        ],
      ),
    );
  }
}

/// What the page shows with no sections to show.
class _WelcomeLine extends StatelessWidget {
  const _WelcomeLine();

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.dashboard_customize_outlined,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const BgeGap.md(),
        Semantics(
          header: true,
          child: Text(
            l10n.homeEmptyStateTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        const BgeGap.sm(),
        Text(
          l10n.homeEmptyStateBody,
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// `child`, or `fallback` in its place while `child` lays out with no height
/// (#1107): the home sections, or the welcome line when none of them draws.
///
/// A section's state lives in it whether it draws or not, so `child` stays
/// mounted, laid out, hit-tested and in the semantics tree throughout, and
/// `fallback` is laid out, painted, hit-tested, offered to screen readers and
/// onstage for finders only while it shows, as an `IndexedStack`'s other
/// children are. The choice is made at layout, in the same frame a section
/// starts or stops drawing.
class _OrWhenBlank extends MultiChildRenderObjectWidget {
  _OrWhenBlank({required Widget child, required Widget fallback})
    : super(children: [child, fallback]);

  @override
  MultiChildRenderObjectElement createElement() => _OrWhenBlankElement(this);

  @override
  _RenderOrWhenBlank createRenderObject(BuildContext context) =>
      _RenderOrWhenBlank();
}

class _OrWhenBlankElement extends MultiChildRenderObjectElement {
  _OrWhenBlankElement(_OrWhenBlank super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    visitor(children.first);
    if ((renderObject as _RenderOrWhenBlank)._blank) visitor(children.last);
  }
}

class _OrWhenBlankParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderOrWhenBlank extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _OrWhenBlankParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _OrWhenBlankParentData> {
  RenderBox get _child => firstChild!;
  RenderBox get _fallback => lastChild!;

  /// Whether [_fallback] shows, as of the last layout.
  bool _blank = false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _OrWhenBlankParentData) {
      child.parentData = _OrWhenBlankParentData();
    }
  }

  @override
  void performLayout() {
    var laidOut = ChildLayoutHelper.layoutChild(_child, constraints);
    final blank = laidOut.height == 0;
    if (blank) {
      laidOut = ChildLayoutHelper.layoutChild(_fallback, constraints);
    }
    if (blank != _blank) {
      _blank = blank;
      markNeedsSemanticsUpdate();
    }
    size = constraints.constrain(laidOut);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final dry = ChildLayoutHelper.dryLayoutChild(_child, constraints);
    return constraints.constrain(
      dry.height == 0
          ? ChildLayoutHelper.dryLayoutChild(_fallback, constraints)
          : dry,
    );
  }

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final dry = ChildLayoutHelper.dryLayoutChild(_child, constraints);
    return (dry.height == 0 ? _fallback : _child).getDryBaseline(
      constraints,
      baseline,
    );
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      (_blank ? _fallback : _child).getDistanceToActualBaseline(baseline);

  double _height(double Function(RenderBox box) height) {
    final child = height(_child);
    return child > 0 ? child : height(_fallback);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _height((box) => box.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _height((box) => box.getMaxIntrinsicHeight(width));

  // Which of the two shows isn't known without a layout, so the widths are
  // the wider of the two's.
  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _child.getMinIntrinsicWidth(height),
    _fallback.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) => math.max(
    _child.getMaxIntrinsicWidth(height),
    _fallback.getMaxIntrinsicWidth(height),
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(_child, offset);
    if (_blank) context.paintChild(_fallback, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      (_blank && _fallback.hitTest(result, position: position)) ||
      _child.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitor(_child);
    if (_blank) visitor(_fallback);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(FlagProperty('blank', value: _blank, ifTrue: 'blank'));
  }
}
