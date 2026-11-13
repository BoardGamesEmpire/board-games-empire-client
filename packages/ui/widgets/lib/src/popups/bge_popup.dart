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
/// **It goes on the root navigator, whatever [context] is under**, so its
/// barrier covers everything drawn around the page as well as the page: the
/// navigation shell's bar or rail, which a pop-up on the shell's nested
/// navigator would leave live beside it (#414).
///
/// **A page opened from it removes it once the page has arrived** (see
/// [BgeRemoveWhenCovered]), so back from that page lands where the pop-up
/// was opened from. The returned future then completes with null, as for any
/// close. A page pushed on the root navigator lands over the pop-up, which
/// hears of it as the route above it (#707). A page pushed on the nested
/// navigator [context] is under arrives beneath the pop-up, which hears of it
/// only through a [BgePopupCoverObserver] installed on that navigator: the
/// pop-up registers with the one it finds there (#414).
///
/// [semanticLabel] names the pop-up to a screen reader as it opens, as
/// `AlertDialog.semanticLabel` does.
Future<T?> showBgePopup<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String semanticLabel,
}) {
  final opener = Navigator.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final coverObserver = opener.widget.observers
      .whereType<BgePopupCoverObserver>()
      .firstOrNull;
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

  final narrow = BgeWindowClass.of(context) == BgeWindowClass.compact;
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
            coverObserver: coverObserver,
          )
        : BgePopupDialogRoute<T>(
            context: context,
            builder: named,
            themes: themes,
            coverObserver: coverObserver,
          ),
  );
}

/// Tells the [showBgePopup] pop-ups opened from a nested navigator's pages
/// of each page pushed on that navigator (#414).
///
/// A pop-up goes on the root navigator, so a page it opens on the nested
/// navigator its opener is on is pushed where the pop-up's route can't see
/// it. Install one of these in that navigator's observers (with go_router,
/// the `ShellRoute`'s `observers:`), and [showBgePopup] registers each pop-up
/// opened from one of its pages with it. The pop-up then goes once such a
/// page has arrived, as [BgeRemoveWhenCovered] says.
///
/// One per navigator, as for any [NavigatorObserver]. The root navigator
/// needs none: a pop-up hears of a page pushed over it there by itself.
class BgePopupCoverObserver extends NavigatorObserver {
  /// The pop-ups registered with this observer and still installed.
  final Set<BgeRemoveWhenCovered<dynamic>> _popups = {};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _covered(route);
  }

  /// A page that replaces another arrives as a pushed one does, as with
  /// [NavigatorState.pushReplacement].
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _covered(newRoute);
  }

  void _covered(Route<dynamic> route) {
    // A copy: a pop-up leaves the set as it is disposed, and nothing here
    // should depend on that never happening mid-loop.
    for (final popup in [..._popups]) {
      popup._pushedBeneath(route);
    }
  }
}

/// Removes a pop-up's route once a page opened from it has arrived (#707,
/// #414).
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
/// So the route watches the page's entrance and removes itself
/// ([NavigatorState.removeRoute]) once the entrance completes. It hears of
/// the page one of two ways:
///
/// - **On its own navigator**, the page is the route pushed above it
///   ([didChangeNext]), and slides in over the pop-up as measured above.
/// - **On a nested navigator**, the one its opener is on when the pop-up is
///   on the root navigator, the page is reported by the
///   [BgePopupCoverObserver] installed there ([coverObserver]), which the
///   route registers with while it is installed (#414). The root navigator
///   paints over the nested one, so the page arrives beneath the pop-up and
///   its scrim, and the pop-up goes once the page has arrived: not in the
///   first frame, when the navigator's [HeroController] holds the page
///   offstage and its entrance reads as complete. Without that observer the
///   pop-up never hears of the page, and stays over it.
///
/// A page popped before it has arrived leaves the pop-up in place: it was
/// never covered.
///
/// **Only an opaque route covers it.** A dialog or a sheet opened from the
/// pop-up, such as a confirmation, is a [TransitionRoute] too, but the
/// pop-up shows through it and is still what the user is working in. Removing
/// it there would drop the pop-up from under the dialog, and closing the
/// dialog would land on the page beneath.
///
/// It watches the page's own [TransitionRoute.animation], not this route's
/// `secondaryAnimation`: a page never transitions from a pop-up, so that
/// animation never runs under a pushed page. Nor the opener's: probed for
/// #414, it caught a page with no transition pushed over Home, a page with
/// no transition either, and missed the same page pushed over a
/// `MaterialPage` opener, one with a transition of its own.
mixin BgeRemoveWhenCovered<T> on TransitionRoute<T> {
  /// The observer on the nested navigator this pop-up was opened from, for
  /// a page pushed there; null when there is none.
  BgePopupCoverObserver? get coverObserver => null;

  /// The page above this route on its own navigator.
  _Entrance? _over;

  /// The pages pushed on [coverObserver]'s navigator. A later one leaves
  /// the earlier ones watched: it can be popped before it arrives, and the
  /// page under it still covers the pop-up once that page arrives.
  final List<_Entrance> _beneath = [];

  @override
  void install() {
    super.install();
    coverObserver?._popups.add(this);
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    _over?.cancel();
    _over = _watch(nextRoute);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    _over?.cancel();
    _over = null;
  }

  @override
  void dispose() {
    coverObserver?._popups.remove(this);
    _over?.cancel();
    for (final entrance in _beneath) {
      entrance.cancel();
    }
    super.dispose();
  }

  /// [coverObserver] saw [route] pushed on its navigator.
  void _pushedBeneath(Route<dynamic> route) {
    // A pop-up on its way out has nothing to remove, and a page on its own
    // navigator is [didChangeNext]'s.
    if (!isActive || identical(route.navigator, navigator)) return;
    final entrance = _watch(route);
    if (entrance != null) _beneath.add(entrance);
  }

  /// Watches [route]'s entrance, if it is a route that covers this one.
  _Entrance? _watch(Route<dynamic>? route) {
    if (route is! TransitionRoute<dynamic> || !route.opaque) return null;
    final animation = route.animation;
    if (animation == null) return null;
    return _Entrance(route, animation, _removeOnceArrived);
  }

  /// Removes this route after the current frame, if [entrance] is still
  /// watched and its page still installed then.
  ///
  /// [NavigatorState.removeRoute] can't run while the navigator is updating
  /// its history, which is where [didChangeNext] and a navigator observer
  /// are called from. Every path waits for the frame to end, so none can land
  /// there.
  void _removeOnceArrived(_Entrance entrance) {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (isActive && !entrance.cancelled && entrance.route.isActive) {
          navigator!.removeRoute(this);
        }
      }, debugLabel: 'BgeRemoveWhenCovered.removeRoute')
      // A post-frame callback asks for no frame of its own.
      ..ensureVisualUpdate();
  }
}

/// A page's entrance, watched for [BgeRemoveWhenCovered] until the page has
/// arrived.
class _Entrance {
  _Entrance(this.route, this._animation, this._onArrived) {
    if (_hasArrived) {
      // A page with no transition arrives before it is announced, so there
      // is no entrance left to wait for.
      _onArrived(this);
    } else {
      _animation.addStatusListener(_changed);
    }
  }

  /// The page.
  final TransitionRoute<dynamic> route;

  /// [route]'s animation, as it was when the watch began.
  final Animation<double> _animation;

  /// Told once the page has arrived.
  final void Function(_Entrance) _onArrived;

  /// Whether the pop-up has stopped watching this page: another took its
  /// place, or the pop-up is gone.
  bool get cancelled => _cancelled;
  bool _cancelled = false;

  /// Whether the entrance has completed with the page on stage.
  ///
  /// A navigator's [HeroController] (go_router gives one to every navigator)
  /// puts a page pushed over another page offstage for its first frame, to
  /// measure its heroes, and an offstage [ModalRoute]'s animation reads as
  /// complete. The entrance starts once the page is back on stage, and its
  /// real completion comes after (#414).
  bool get _hasArrived {
    final page = route;
    return _animation.isCompleted && !(page is ModalRoute && page.offstage);
  }

  void _changed(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.completed:
        // Offstage for the hero frame: still listening for the real one.
        if (!_hasArrived) return;
        _stopListening();
        _onArrived(this);
      case AnimationStatus.dismissed:
        _stopListening();
      case AnimationStatus.forward || AnimationStatus.reverse:
        break;
    }
  }

  /// Stops watching, and keeps a removal already asked for from happening.
  void cancel() {
    _cancelled = true;
    _stopListening();
  }

  void _stopListening() => _animation.removeStatusListener(_changed);
}

/// [showBgePopup]'s bottom sheet, for a narrow window (#707).
///
/// It grows with its content up to the safe area, and has a drag handle.
///
/// The sheet's own safe area keeps it clear of the top and the sides only,
/// so its surface reaches the bottom edge. Its content stops above the
/// system navigation or the home indicator there, so the last action is
/// never under it.
class BgePopupSheetRoute<T> extends ModalBottomSheetRoute<T>
    with BgeRemoveWhenCovered<T> {
  /// A sheet showing [builder]'s content.
  BgePopupSheetRoute({
    required WidgetBuilder builder,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.modalBarrierColor,
    super.settings,
    this.coverObserver,
  }) : super(
         builder: (context) => SafeArea(top: false, child: builder(context)),
         isScrollControlled: true,
         showDragHandle: true,
         useSafeArea: true,
       );

  @override
  final BgePopupCoverObserver? coverObserver;
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
    this.coverObserver,
  }) : _themedBarrierColor = DialogTheme.of(context).barrierColor,
       super(
         builder: (context) => Dialog(child: Builder(builder: builder)),
         // As `showDialog` has it: Tab stays inside the dialog.
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
       );

  final Color? _themedBarrierColor;

  @override
  final BgePopupCoverObserver? coverObserver;

  /// The dialog theme's barrier, as `showDialog` takes it, or else
  /// [DialogRoute]'s own.
  @override
  Color? get barrierColor => _themedBarrierColor ?? super.barrierColor;
}
