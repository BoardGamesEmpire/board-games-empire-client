import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens [builder]'s content as a pop-up over the page: a bottom sheet in a
/// window narrower than [BgeTokens.breakpointMedium], and a dialog no wider
/// than [BgeTokens.contentMaxWidth] from there up (#707).
///
/// A sheet at every width was the app's habit, but from 840dp up it is a wide
/// strip along the bottom edge, where #707 asks for a dialog sized to its
/// content.
///
/// **It goes on the root navigator, whatever [context] is under.** Home sits
/// on the auth `ShellRoute`'s nested navigator, and the pages a pop-up opens
/// are pushed on the root one. Probed for #707: a pop-up on the nested
/// navigator never hears of a page pushed on the root navigator, so it stays
/// beneath it and back lands on it.
///
/// **A page pushed over it removes it once the page has arrived** (see
/// [BgeRemoveWhenCovered]), so back from that page lands where the pop-up
/// was opened from. The returned future then completes with null, as for any
/// close.
///
/// [semanticLabel] names the pop-up to a screen reader as it opens, as
/// `AlertDialog.semanticLabel` does.
Future<T?> showBgePopup<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String semanticLabel,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  // A Theme or IconTheme set between the root navigator and [context] would
  // not reach a route on the root navigator. Captured, the content keeps it.
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final localizations = MaterialLocalizations.of(context);
  Widget named(BuildContext context) => Semantics(
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: semanticLabel,
    child: builder(context),
  );

  final narrow =
      MediaQuery.sizeOf(context).width < BgeTokens.of(context).breakpointMedium;
  return navigator.push<T>(
    narrow
        // The barrier as `showModalBottomSheet` gives it.
        ? BgePopupSheetRoute<T>(
            builder: named,
            capturedThemes: themes,
            barrierLabel: localizations.scrimLabel,
            barrierOnTapHint: localizations.scrimOnTapHint(
              localizations.bottomSheetLabel,
            ),
            modalBarrierColor: Theme.of(context)
                .bottomSheetTheme
                .modalBarrierColor,
          )
        : BgePopupDialogRoute<T>(
            context: context,
            builder: named,
            themes: themes,
          ),
  );
}

/// Removes a pop-up's route once a page pushed over it has arrived (#707).
///
/// Opening a page from a pop-up was measured four ways on Android and iOS
/// page transitions, for a sheet and a dialog:
///
/// - **Close, then push, in one frame:** the sheet slides down, or the dialog
///   fades, under the arriving page. Two things move at once.
/// - **Push, and remove the pop-up in the same frame:** the pop-up vanishes at
///   once, and on iOS the strip the sliding page hasn't reached yet shows the
///   page beneath without it.
/// - **Push, and remove the pop-up when the page is popped:** on the root
///   navigator the removal waits for the page's exit, so a dialog shows while
///   the page slides away.
/// - **Push, and remove the pop-up once the page has arrived:** the pop-up
///   sits still under the arriving page and goes once it is covered. Back
///   (the button or the iOS edge swipe) lands with no pop-up. This one.
///
/// So the route watches the route pushed above it ([didChangeNext]) and
/// removes itself ([NavigatorState.removeRoute]) once that route's entrance
/// completes. A page popped before it has arrived leaves the pop-up in place:
/// it was never covered.
///
/// **Only an opaque route covers it.** A dialog or a sheet opened from the
/// pop-up, such as a confirmation, is a [TransitionRoute] too, but the
/// pop-up shows through it and is still what the user is working in. Removing
/// it there would drop the pop-up from under the dialog, and closing the
/// dialog would land on the page beneath.
///
/// It watches the next route's own [TransitionRoute.animation], not this
/// route's `secondaryAnimation`: a page never transitions from a pop-up, so
/// that animation never runs under a pushed page.
mixin BgeRemoveWhenCovered<T> on TransitionRoute<T> {
  /// The route above this one, as [didChangeNext] last said.
  Route<dynamic>? _next;

  /// The entrance of [_next], while it is under way.
  Animation<double>? _entrance;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    _stopWatching();
    _next = nextRoute;
    if (nextRoute is! TransitionRoute<dynamic> || !nextRoute.opaque) return;
    final entrance = nextRoute.animation;
    if (entrance == null) return;
    if (entrance.isCompleted) {
      // A page with no transition arrives before it is announced here, so
      // there is no entrance left to wait for.
      _removeOnceCoveredBy(nextRoute);
    } else {
      _entrance = entrance..addStatusListener(_entranceChanged);
    }
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    _stopWatching();
    _next = null;
  }

  @override
  void dispose() {
    _stopWatching();
    super.dispose();
  }

  void _entranceChanged(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.completed:
        _stopWatching();
        final next = _next;
        if (next != null) _removeOnceCoveredBy(next);
      case AnimationStatus.dismissed:
        _stopWatching();
      case AnimationStatus.forward || AnimationStatus.reverse:
        break;
    }
  }

  void _stopWatching() {
    _entrance?.removeStatusListener(_entranceChanged);
    _entrance = null;
  }

  /// Removes this route after the current frame, if [cover] is still above
  /// it then.
  ///
  /// [NavigatorState.removeRoute] can't run while the navigator is updating
  /// its history, which is where [didChangeNext] is called from. Both paths
  /// wait for the frame to end, so neither can land there.
  void _removeOnceCoveredBy(Route<dynamic> cover) {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (isActive && identical(_next, cover) && cover.isActive) {
          navigator!.removeRoute(this);
        }
      }, debugLabel: 'BgeRemoveWhenCovered.removeRoute')
      // A post-frame callback asks for no frame of its own.
      ..ensureVisualUpdate();
  }
}

/// [showBgePopup]'s bottom sheet, for a narrow window (#707).
///
/// It grows with its content up to the safe area, and has a drag handle.
class BgePopupSheetRoute<T> extends ModalBottomSheetRoute<T>
    with BgeRemoveWhenCovered<T> {
  /// A sheet showing [builder]'s content.
  BgePopupSheetRoute({
    required super.builder,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.modalBarrierColor,
    super.settings,
  }) : super(isScrollControlled: true, showDragHandle: true, useSafeArea: true);
}

/// [showBgePopup]'s dialog, for a window from
/// [BgeTokens.breakpointMedium] up (#707).
///
/// As wide as its content, up to the cap the app's dialog theme sets at
/// [BgeTokens.contentMaxWidth], as for every other dialog.
class BgePopupDialogRoute<T> extends DialogRoute<T>
    with BgeRemoveWhenCovered<T> {
  /// A dialog showing [builder]'s content.
  BgePopupDialogRoute({
    required super.context,
    required WidgetBuilder builder,
    super.themes,
    super.barrierLabel,
    super.settings,
  }) : _themedBarrierColor = DialogTheme.of(context).barrierColor,
       super(
         builder: (context) => Dialog(child: Builder(builder: builder)),
         // As `showDialog` has it: Tab stays inside the dialog.
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
       );

  final Color? _themedBarrierColor;

  /// The dialog theme's barrier, as `showDialog` takes it, or else
  /// [DialogRoute]'s own.
  @override
  Color? get barrierColor => _themedBarrierColor ?? super.barrierColor;
}
