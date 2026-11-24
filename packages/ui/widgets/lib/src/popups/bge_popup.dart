import 'dart:ui' show SemanticsHitTestBehavior;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens [builder]'s content as a pop-up over the page: a bottom sheet in a
/// window narrower than [BgeTokens.breakpointMedium] (the one [context] is
/// under), and a dialog no wider than [BgeTokens.contentMaxWidth] from there
/// up (#707).
///
/// A sheet at every width was the app's habit, but from 840dp up it is a wide
/// strip along the bottom edge, where #707 asks for a dialog sized to its
/// content.
///
/// **The form follows the window for as long as the pop-up is open** (#733).
/// A sheet whose window is widened past the breakpoint, or rotated to
/// landscape, is redrawn as a dialog, and a dialog whose window is narrowed
/// as a sheet. It is one route throughout ([BgePopupRoute]) and [builder]'s
/// content is one subtree, so what the content holds survives the change:
/// its state, its scroll position and the focus in it. Content that lays
/// out differently in each form reads [BgePopupForm.maybeOf].
///
/// **The change of form is instant**: a resize is not animated. The
/// entrance and the exit animate in the form the pop-up has when they run,
/// so a sheet slides and a dialog fades. Only the sheet form can be dragged
/// down to close.
///
/// For content authors: across a change of form the content's subtree is
/// moved to a new parent under a [GlobalKey], so its [State]s are kept, but
/// their [State.didChangeDependencies] runs again.
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
  // The breakpoint is the opener's for the same reason. The page, the
  // barrier and the transition are built where the root navigator's theme
  // is, so they are given it rather than read it there.
  final tokens = BgeTokens.of(context);
  // A node of its own in both forms (`container`). Left to merge upwards,
  // it joins a node of `Dialog`'s in dialog form, and is then a different
  // node in each form: see `_PopupPage` for what that costs in a browser.
  Widget named(BuildContext context) => Semantics(
    container: true,
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: semanticLabel,
    child: builder(context),
  );

  return navigator.push<T>(
    BgePopupRoute<T>._(
      builder: named,
      themes: themes,
      tokens: tokens,
      form: BgePopupForm._forWindow(context, tokens),
      // Both forms' barrier colours and labels are settled here, from the
      // opener's theme and localizations, as `showModalBottomSheet` and
      // `showDialog` settle theirs. The barrier is built beside the page,
      // outside [themes], so read there it would miss a theme the opener
      // is under.
      sheetTraits: _FormTraits.sheet(context),
      dialogTraits: _FormTraits.dialog(context),
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

  /// A page removed outright ([NavigatorState.removeRoute], or a router
  /// dropping it) runs no exit, so this is all that says it went.
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    for (final popup in [..._popups]) {
      popup._removedBeneath(route);
    }
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

  /// Whether a page opened through [openPage] is on its way.
  bool _opening = false;

  /// Runs [open], which opens a page from this pop-up, unless a page it
  /// opened is still on its way (#978). Returns whether [open] ran.
  ///
  /// So a pop-up opens its page once, however often what opens it is pressed
  /// while the page arrives: on a nested navigator the page arrives beneath
  /// the pop-up, which stays on top, pressable, until the page has. And a
  /// page pushed through a router is pushed a frame after the press, so two
  /// presses can land before there is any page to see.
  ///
  /// A page on its way stays so until it has arrived, which removes the
  /// pop-up, or leaves before it arrives, popped or removed outright, which
  /// leaves the pop-up in place and lets the next press open a page again.
  bool openPage(VoidCallback open) {
    if (_opening) return false;
    _opening = true;
    try {
      open();
    } catch (_) {
      _opening = false;
      rethrow;
    }
    return true;
  }

  /// A page this pop-up watched left before it arrived.
  ///
  /// It lifts the guard only once no watched page is still on its way. The
  /// pop-up can't tell which page [openPage]'s callback pushed: a router
  /// pushes it a frame later. Any page that comes and goes on the nested
  /// navigator while that one arrives is watched too, and its leaving
  /// mustn't let a second press open the page again.
  void _pageLeft() {
    if (_over?.onItsWay ?? false) return;
    if (_beneath.any((entrance) => entrance.onItsWay)) return;
    _opening = false;
  }

  @override
  void install() {
    super.install();
    coverObserver?._popups.add(this);
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    final previous = _over;
    _over = _watch(nextRoute);
    // A page still on its way that is no longer next was removed outright,
    // which runs no exit, or replaced: told after [_over] is the page now
    // next, which keeps the guard while it arrives.
    previous
      ?..left()
      ..cancel();
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    _over?.cancel();
    _over = null;
    // A page that had arrived would have removed this route, so this one
    // was popped on its way.
    _pageLeft();
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

  /// [coverObserver] saw [route] removed outright from its navigator.
  void _removedBeneath(Route<dynamic> route) {
    for (final entrance in [..._beneath]) {
      if (identical(entrance.route, route)) entrance.left();
    }
  }

  /// Watches [route]'s entrance, if it is a route that covers this one.
  _Entrance? _watch(Route<dynamic>? route) {
    if (route is! TransitionRoute<dynamic> || !route.opaque) return null;
    final animation = route.animation;
    if (animation == null) return null;
    return _Entrance(route, animation, _removeOnceArrived, _pageLeft);
  }

  /// Removes this route after the current frame, if [entrance] is still
  /// watched and its page still installed then.
  ///
  /// [NavigatorState.removeRoute] can't run while the navigator is updating
  /// its history, which is where [didChangeNext] and a navigator observer
  /// are called from. Every path waits for the frame to end, so none can land
  /// there.
  ///
  /// A page removed outright after it arrived but before the frame ended
  /// never covered the pop-up, and [_Entrance.left] has nothing to tell of
  /// a page that arrived, so the guard is lifted here.
  void _removeOnceArrived(_Entrance entrance) {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!isActive) return;
        if (!entrance.route.isActive) {
          _pageLeft();
        } else if (!entrance.cancelled) {
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
  _Entrance(this.route, this._animation, this._onArrived, this._onLeft) {
    if (_hasArrived) {
      // A page with no transition arrives before it is announced, so there
      // is no entrance left to wait for.
      _ended = true;
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

  /// Told if the page leaves before it has arrived: see [left].
  final VoidCallback _onLeft;

  /// Whether the pop-up has stopped watching this page: another took its
  /// place, or the pop-up is gone.
  bool get cancelled => _cancelled;
  bool _cancelled = false;

  /// Whether the page has arrived or left.
  bool _ended = false;

  /// Whether the page is still arriving: watched, neither arrived nor left,
  /// and still on its navigator. The last holds for a page removed outright
  /// before [left] is told of it.
  bool get onItsWay => !_cancelled && !_ended && route.isActive;

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
        _ended = true;
        _stopListening();
        _onArrived(this);
      case AnimationStatus.dismissed:
        left();
      case AnimationStatus.forward || AnimationStatus.reverse:
        break;
    }
  }

  /// The page left before it arrived: popped, when its exit ends, or
  /// removed outright, which runs no exit, when its navigator says so. A
  /// page that has arrived, or one no longer watched, has nothing to tell.
  void left() {
    if (_ended || _cancelled) return;
    _ended = true;
    _stopListening();
    _onLeft();
  }

  /// Stops watching, and keeps a removal already asked for from happening.
  void cancel() {
    _cancelled = true;
    _stopListening();
  }

  void _stopListening() => _animation.removeStatusListener(_changed);
}

/// The form a [showBgePopup] pop-up is drawn in (#733).
enum BgePopupForm {
  /// A bottom sheet, in a window narrower than [BgeTokens.breakpointMedium].
  sheet,

  /// A dialog, in a window from [BgeTokens.breakpointMedium] up.
  dialog;

  /// The form of the pop-up [context] is in, or null outside one.
  ///
  /// [context] is rebuilt when the pop-up changes form. `ModalRoute.of`
  /// can't say which form it is in, and rebuilds nothing on a change: the
  /// route is the same one in both.
  static BgePopupForm? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PopupFormScope>()?.form;

  /// The form a pop-up takes in the window [context] is in, against the
  /// breakpoint in [tokens]. [context] is rebuilt when the window's width
  /// changes.
  static BgePopupForm _forWindow(BuildContext context, BgeTokens tokens) =>
      BgeWindowClass.fromWidth(MediaQuery.sizeOf(context).width, tokens) ==
          BgeWindowClass.compact
      ? sheet
      : dialog;
}

/// Tells a pop-up's content which form it is drawn in.
class _PopupFormScope extends InheritedWidget {
  const _PopupFormScope({required this.form, required super.child});

  final BgePopupForm form;

  @override
  bool updateShouldNotify(_PopupFormScope oldWidget) => form != oldWidget.form;
}

/// What the pop-up's route answers in one of its forms: the barrier under
/// it, how long it takes to arrive and to leave, and where Tab goes from
/// its last control.
///
/// Each answer is the one Flutter's own route for that form gives, so the
/// pop-up matches every other sheet and dialog in the app, which
/// `showModalBottomSheet` and `showDialog` open. Flutter keeps a sheet's and
/// a dialog's default barrier colour and their durations inside those
/// routes, with no constant to read, so each is asked of a route that is
/// never pushed.
@immutable
class _FormTraits {
  const _FormTraits._({
    required this.barrierColor,
    required this.barrierLabel,
    required this.barrierOnTapHint,
    required this.transitionDuration,
    required this.reverseTransitionDuration,
    required this.traversalEdgeBehavior,
  });

  /// A sheet's, as `showModalBottomSheet` gives them under [context]'s
  /// theme.
  factory _FormTraits.sheet(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return _FormTraits._of(
      ModalBottomSheetRoute<void>(
        builder: _nothing,
        isScrollControlled: true,
        barrierLabel: localizations.scrimLabel,
        modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
      ),
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
    );
  }

  /// A dialog's, as `showDialog` gives them under [context]'s theme.
  factory _FormTraits.dialog(BuildContext context) => _FormTraits._of(
    DialogRoute<void>(
      context: context,
      builder: _nothing,
      // As `showDialog` has it: Tab stays inside the dialog.
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    ),
    // The dialog theme's barrier, as `showDialog` takes it, or else
    // [DialogRoute]'s own.
    barrierColor: DialogTheme.of(context).barrierColor,
  );

  /// [route]'s answers, with [barrierColor] in place of its own where one
  /// is given. [route] is disposed of: it was made to be asked.
  factory _FormTraits._of(
    ModalRoute<void> route, {
    Color? barrierColor,
    String? barrierOnTapHint,
  }) {
    final traits = _FormTraits._(
      barrierColor: barrierColor ?? route.barrierColor,
      barrierLabel: route.barrierLabel,
      barrierOnTapHint: barrierOnTapHint,
      transitionDuration: route.transitionDuration,
      reverseTransitionDuration: route.reverseTransitionDuration,
      traversalEdgeBehavior: route.traversalEdgeBehavior,
    );
    route.dispose();
    return traits;
  }

  static Widget _nothing(BuildContext context) => const SizedBox.shrink();

  /// The colour the page under the pop-up is dimmed with.
  final Color? barrierColor;

  /// What a screen reader calls the barrier.
  final String? barrierLabel;

  /// What a screen reader says a tap on the barrier does, where the form
  /// says so.
  final String? barrierOnTapHint;

  /// How long the entrance takes.
  final Duration transitionDuration;

  /// How long the exit takes.
  final Duration reverseTransitionDuration;

  /// Where Tab goes from the last control; null for the navigator's own.
  final TraversalEdgeBehavior? traversalEdgeBehavior;
}

/// [showBgePopup]'s route: one route whose page is drawn as a bottom sheet
/// in a window narrower than [BgeTokens.breakpointMedium] and as a dialog
/// from there up, and redrawn as the other when the window crosses that
/// width while it is open (#707, #733).
///
/// A route's kind can't change once it is pushed, and replacing a sheet's
/// route with a dialog's would build the content again: an import being
/// followed, a ticked checklist and the focus would go with the old one.
/// So this is neither a `ModalBottomSheetRoute` nor a `DialogRoute`. It
/// draws what each of them draws, and answers what each of them answers
/// (see [form]), and holds the content under one global key, so the same
/// elements move from the sheet into the dialog and back.
///
/// - **As a sheet** it grows with its content up to the safe area, has a
///   drag handle, and can be dragged down to close. Its own safe area keeps
///   it clear of the top and the sides only, so its surface reaches the
///   bottom edge. Its content stops above the system navigation or the home
///   indicator there, so the last action is never under it.
/// - **As a dialog** it is as wide as its content, up to the cap the app's
///   dialog theme sets at [BgeTokens.contentMaxWidth], as for every other
///   dialog, and Tab stays inside it.
///
/// **The change of form takes no time.** A resize is not something to
/// animate. The entrance and the exit are the ones of the form it has while
/// they run: a sheet slides up and down, and a dialog fades.
///
/// Everything that reads the form reads the window's width from its own
/// place in the tree, against the opener's breakpoint ([_formIn]): the page,
/// the barrier and the transition. A route can't rebuild its barrier from
/// inside its page's build, so the three don't pass the form to each other.
/// They rebuild in the frame the window changes, and agree by reading the
/// same window against the same breakpoint.
///
/// Built by [showBgePopup] only.
class BgePopupRoute<T> extends PopupRoute<T> with BgeRemoveWhenCovered<T> {
  BgePopupRoute._({
    required this._builder,
    required this._themes,
    required this._tokens,
    required this._form,
    required this._sheetTraits,
    required this._dialogTraits,
    this.coverObserver,
  });

  final WidgetBuilder _builder;
  final CapturedThemes _themes;

  /// The opener's tokens, whose breakpoint decides the form.
  final BgeTokens _tokens;
  final _FormTraits _sheetTraits;
  final _FormTraits _dialogTraits;

  @override
  final BgePopupCoverObserver? coverObserver;

  /// The caller's content. One element for as long as the route lives: a
  /// change of form moves it from one form's surface to the other's.
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'BgePopupRoute content');

  /// How much of the barrier the sheet covers, from the bottom edge up. A
  /// screen reader's focus on the barrier leaves that part out, as
  /// [ModalBottomSheetRoute]'s does.
  final ValueNotifier<EdgeInsets> _sheetCover = ValueNotifier(EdgeInsets.zero);

  /// The dialog's fade, eased as [DialogRoute]'s is.
  CurvedAnimation? _dialogFade;

  /// The form the pop-up is drawn in.
  ///
  /// The form it was opened in until its page is first built, and from then
  /// on the form its page was last built in. The route's own answers follow
  /// it: [barrierColor], [barrierLabel], [transitionDuration],
  /// [reverseTransitionDuration] and [traversalEdgeBehavior] are a sheet's
  /// while it is a sheet and a dialog's while it is a dialog.
  @visibleForTesting
  BgePopupForm get form => _form;
  BgePopupForm _form;

  /// The form for the window [context] is in, at the opener's breakpoint.
  /// [context] is rebuilt when the window's width changes.
  BgePopupForm _formIn(BuildContext context) =>
      BgePopupForm._forWindow(context, _tokens);

  _FormTraits _traitsOf(BgePopupForm form) => switch (form) {
    BgePopupForm.sheet => _sheetTraits,
    BgePopupForm.dialog => _dialogTraits,
  };

  AnimationController get _controller => controller!;

  @override
  Color? get barrierColor => _traitsOf(_form).barrierColor;

  @override
  String? get barrierLabel => _traitsOf(_form).barrierLabel;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => _traitsOf(_form).transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _traitsOf(_form).reverseTransitionDuration;

  @override
  TraversalEdgeBehavior? get traversalEdgeBehavior =>
      _traitsOf(_form).traversalEdgeBehavior;

  /// The page is drawn in [form] from this frame on, under [scope], the
  /// route's focus scope.
  ///
  /// Called from the page's build phase, where the route can mark nothing
  /// outside the page for a rebuild. It changes only what no widget is built
  /// from.
  void _drawnAs(BgePopupForm form, FocusScopeNode scope) {
    if (form == _form) return;
    _form = form;
    // The exit, and an entrance not yet started, take as long as this
    // form's do. One under way keeps the time it started with.
    _controller
      ..duration = transitionDuration
      ..reverseDuration = reverseTransitionDuration;
    // What the route's scope was given when it was built, for the form it
    // had then.
    scope.traversalEdgeBehavior =
        traversalEdgeBehavior ?? navigator!.widget.routeTraversalEdgeBehavior;
    // A finger dragging the sheet holds the entrance part of the way, and
    // only the sheet hears that finger lift. The dialog would stay as faint
    // as the sheet was low, so the entrance is finished from where it was
    // held. A back gesture holds it too, and finishes it itself.
    if (isActive &&
        !navigator!.userGestureInProgress &&
        !_controller.isAnimating &&
        !_controller.isCompleted) {
      _controller.forward();
    }
  }

  /// The sheet was laid out [size] tall.
  void _sheetSized(Size size) =>
      _sheetCover.value = EdgeInsets.only(bottom: size.height);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _PopupPage<T>(route: this);

  /// A dialog fades in and out, as [DialogRoute] has it. A sheet slides
  /// inside its page, where its height is known, so it is not faded here.
  ///
  /// The [FadeTransition] is there in both forms, opaque for a sheet. With
  /// it gone for a sheet, each change of form would move the whole page to
  /// a new place in the tree.
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: switch (_formIn(context)) {
      BgePopupForm.sheet => kAlwaysCompleteAnimation,
      BgePopupForm.dialog => _fadeOf(animation),
    },
    child: child,
  );

  CurvedAnimation _fadeOf(Animation<double> animation) {
    final fade = _dialogFade;
    if (fade != null && fade.parent == animation) return fade;
    fade?.dispose();
    return _dialogFade = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeOut,
    );
  }

  @override
  Widget buildModalBarrier() => _PopupBarrier<T>(route: this);

  @override
  void dispose() {
    _dialogFade?.dispose();
    _sheetCover.dispose();
    super.dispose();
  }
}

/// [BgePopupRoute]'s barrier: the one `showModalBottomSheet` puts under a
/// sheet while the window is compact, and the one `showDialog` puts under a
/// dialog otherwise.
///
/// A sheet's barrier has its own label and tap hint, and its screen-reader
/// focus stops at the sheet's top edge. Built as [ModalRoute] and
/// [ModalBottomSheetRoute] build theirs, which read the route's colour once
/// per build: this one is built again when the window changes class,
/// because it reads the class itself.
class _PopupBarrier<T> extends StatelessWidget {
  const _PopupBarrier({required this.route});

  final BgePopupRoute<T> route;

  @override
  Widget build(BuildContext context) {
    final form = route._formIn(context);
    final traits = route._traitsOf(form);
    final cover = switch (form) {
      BgePopupForm.sheet => route._sheetCover,
      BgePopupForm.dialog => null,
    };
    final color = traits.barrierColor;
    if (color == null || color.a == 0 || route.offstage) {
      return ModalBarrier(
        dismissible: route.barrierDismissible,
        semanticsLabel: traits.barrierLabel,
        barrierSemanticsDismissible: route.semanticsDismissible,
        clipDetailsNotifier: cover,
        semanticsOnTapHint: traits.barrierOnTapHint,
      );
    }
    return AnimatedModalBarrier(
      color: route.animation!.drive(
        ColorTween(
          begin: color.withValues(alpha: 0),
          end: color,
        ).chain(CurveTween(curve: route.barrierCurve)),
      ),
      dismissible: route.barrierDismissible,
      semanticsLabel: traits.barrierLabel,
      barrierSemanticsDismissible: route.semanticsDismissible,
      clipDetailsNotifier: cover,
      semanticsOnTapHint: traits.barrierOnTapHint,
    );
  }
}

/// [BgePopupRoute]'s page: the caller's content on a sheet's surface or a
/// dialog's, by the window's class.
///
/// **What is around the surface is the same widgets in both forms, and only
/// what they are told differs.** A browser's screen reader reads elements the
/// web engine builds from the semantics tree, one for each node. A node that
/// gets a new parent has its element moved, and one whose role changes has
/// it rebuilt, and the browser takes focus off anything inside an element as
/// it moves. Drawn as each form's own route draws it
/// ([ModalBottomSheetRoute], and [DialogRoute] over `RawDialogRoute`), the
/// content's node had the sheet's route node above it in one form and the
/// dialog's nodes in the other, and a change of form put keyboard focus out
/// of the pop-up in a browser with a screen reader on (#733).
///
/// So the three nodes over the content stay, whichever form is drawn:
///
/// 1. **The route's.** In sheet form it is named as a modal sheet's is. In
///    dialog form it has no name, as a dialog's has none.
/// 2. **The one that keeps a click on the pop-up from reaching the
///    barrier.**
/// 3. **The dialog role's**, which [Dialog] would give itself. A modal sheet
///    is a modal dialog to a browser too, and only the web engine reads the
///    role. It is a node of its own (`container`), so what [Dialog] still
///    annotates joins it and adds none between it and the content.
///
/// The dialog form's nodes are [DialogRoute]'s, in its order. The sheet
/// form's are [ModalBottomSheetRoute]'s with the first two the other way
/// round, and the third added.
///
/// Each form's safe area and hinge handling are in its own route's order: a
/// sheet keeps clear of the top and the sides before it picks a side of a
/// hinge, and a dialog after. One of the two [SafeArea]s here is switched
/// off in each form, and stays in the tree for the reason the nodes do.
class _PopupPage<T> extends StatefulWidget {
  const _PopupPage({required this.route});

  final BgePopupRoute<T> route;

  @override
  State<_PopupPage<T>> createState() => _PopupPageState<T>();
}

class _PopupPageState<T> extends State<_PopupPage<T>> {
  late BgePopupForm _form;

  /// The caller's content, under the route's key.
  ///
  /// Made once for each page the route asks for, not once a build. A resize
  /// builds this page again, and the same widget keeps the content from
  /// being built again with it, as neither a sheet's route nor a dialog's
  /// builds its content on a resize.
  late Widget _content;

  Widget _keyedContent() => KeyedSubtree(
    key: widget.route._contentKey,
    child: Builder(builder: widget.route._builder),
  );

  @override
  void initState() {
    super.initState();
    _content = _keyedContent();
  }

  @override
  void didUpdateWidget(_PopupPage<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The route asked for its page again, as it does when what the
    // caller's builder reads from outside may have changed.
    _content = _keyedContent();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _form = widget.route._formIn(context);
    // No dependency: the scope is the route's for the route's whole life,
    // and one would rebuild this page each time focus moves in it.
    widget.route._drawnAs(
      _form,
      FocusScope.of(context, createDependency: false),
    );
  }

  /// What a modal sheet's route is called to a screen reader, as
  /// `showModalBottomSheet` has it. The pop-up's own name is on its content.
  String _sheetRouteLabel(MaterialLocalizations localizations) =>
      switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.macOS => '',
        TargetPlatform.android ||
        TargetPlatform.fuchsia ||
        TargetPlatform.linux ||
        TargetPlatform.windows => localizations.dialogLabel,
      };

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final sheet = _form == BgePopupForm.sheet;
    final content = _PopupFormScope(form: _form, child: _content);
    return route._themes.wrap(
      Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: sheet,
        label: sheet
            ? _sheetRouteLabel(MaterialLocalizations.of(context))
            : null,
        // The sheet's: its surface reaches the bottom edge.
        child: SafeArea(
          left: sheet,
          top: sheet,
          right: sheet,
          bottom: false,
          child: DisplayFeatureSubScreen(
            child: Semantics(
              hitTestBehavior: SemanticsHitTestBehavior.opaque,
              // The dialog's.
              child: SafeArea(
                left: !sheet,
                top: !sheet,
                right: !sheet,
                bottom: !sheet,
                child: Semantics(
                  container: true,
                  role: SemanticsRole.dialog,
                  child: switch (_form) {
                    BgePopupForm.sheet => _PopupSheet<T>(
                      route: route,
                      child: SafeArea(top: false, child: content),
                    ),
                    BgePopupForm.dialog => Dialog(
                      semanticsRole: SemanticsRole.none,
                      child: content,
                    ),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet form of [BgePopupRoute]'s page: a [BottomSheet] with a drag
/// handle, resting on the bottom edge, that slides up as the route arrives
/// and down as it leaves, and follows a finger dragging it down to close.
///
/// What `showModalBottomSheet`'s route puts around a [BottomSheet], which
/// Flutter keeps private to that route, but for the route's semantics node:
/// that one is [_PopupPage]'s, where both forms share it. The drag is
/// [BottomSheet]'s own: it moves the route's animation directly, and pops
/// the route when let go far enough down or fast enough.
class _PopupSheet<T> extends StatefulWidget {
  const _PopupSheet({required this.route, required this.child});

  final BgePopupRoute<T> route;
  final Widget child;

  @override
  State<_PopupSheet<T>> createState() => _PopupSheetState<T>();
}

class _PopupSheetState<T> extends State<_PopupSheet<T>> {
  /// The curve a modal sheet arrives and leaves on.
  static const Curve _curve = Easing.legacyDecelerate;

  /// How far up the sheet is, from 0 (below the bottom edge) to 1 (at
  /// rest): the route's animation, eased, except around a drag.
  late final ProxyAnimation _position;

  /// The route's animation eased from end to end, which [_position] follows
  /// until the first drag.
  late final CurvedAnimation _eased;

  /// The route's animation eased from where the last drag let go, which
  /// [_position] follows after it.
  CurvedAnimation? _easedFromRelease;

  @override
  void initState() {
    super.initState();
    _eased = CurvedAnimation(
      parent: widget.route.animation!,
      curve: _curve,
      reverseCurve: _curve,
    );
    _position = ProxyAnimation(_eased);
  }

  @override
  void dispose() {
    // Detached, so nothing is left listening to the route's animation.
    _position.parent = kAlwaysDismissedAnimation;
    _eased.dispose();
    _easedFromRelease?.dispose();
    super.dispose();
  }

  /// Under a finger the sheet follows the animation as it is, with no
  /// easing, so it stays under the finger.
  void _onDragStart(DragStartDetails details) =>
      _position.parent = widget.route.animation;

  /// Let go, the sheet eases the rest of the way from where it was, up or
  /// down, with no jump.
  void _onDragEnd(DragEndDetails details, {required bool isClosing}) {
    final animation = widget.route.animation!;
    final released = Split(animation.value, endCurve: _curve);
    final eased = CurvedAnimation(
      parent: animation,
      curve: released,
      reverseCurve: released,
    );
    _position.parent = eased;
    _easedFromRelease?.dispose();
    _easedFromRelease = eased;
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final theme = Theme.of(context).bottomSheetTheme;
    return AnimatedBuilder(
      animation: _position,
      builder: (context, child) => ClipRect(
        child: _SheetLayout(
          position: _position.value,
          onSized: route._sheetSized,
          child: child,
        ),
      ),
      child: BottomSheet(
        animationController: route._controller,
        onClosing: () {
          if (route.isCurrent) Navigator.pop(context);
        },
        builder: (_) => widget.child,
        // A modal sheet's colour and elevation, where the theme names
        // them: [BottomSheet] falls back as the modal route does.
        backgroundColor: theme.modalBackgroundColor,
        elevation: theme.modalElevation,
        showDragHandle: true,
        onDragStart: _onDragStart,
        onDragEnd: _onDragEnd,
      ),
    );
  }
}

/// Lays the sheet out as wide as the window and as tall as its content, up
/// to the window's height, with [position] of it above the bottom edge.
///
/// [onSized] hears the sheet's size whenever it changes, during layout.
class _SheetLayout extends SingleChildRenderObjectWidget {
  const _SheetLayout({
    required this.position,
    required this.onSized,
    super.child,
  });

  final double position;
  final ValueChanged<Size> onSized;

  @override
  _RenderSheetLayout createRenderObject(BuildContext context) =>
      _RenderSheetLayout(position: position, onSized: onSized);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSheetLayout renderObject,
  ) => renderObject
    ..position = position
    ..onSized = onSized;
}

class _RenderSheetLayout extends RenderShiftedBox {
  _RenderSheetLayout({required this._position, required this.onSized})
    : super(null);

  ValueChanged<Size> onSized;

  Size? _sized;

  double get position => _position;
  double _position;
  set position(double value) {
    if (_position == value) return;
    _position = value;
    markNeedsLayout();
  }

  /// As wide as the window, and no taller than it.
  BoxConstraints _childConstraints(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: constraints.maxWidth,
        maxWidth: constraints.maxWidth,
        maxHeight: constraints.maxHeight,
      );

  Offset _childOffset(Size size, Size childSize) =>
      Offset(0, size.height - childSize.height * position);

  // It fills what it is given, whatever its child would like.
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final child = this.child;
    if (child == null) return null;
    final childConstraints = _childConstraints(constraints);
    final result = child.getDryBaseline(childConstraints, baseline);
    if (result == null) return null;
    final childSize = child.getDryLayout(childConstraints);
    return result + _childOffset(constraints.biggest, childSize).dy;
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) return;
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    (child.parentData! as BoxParentData).offset = _childOffset(
      size,
      child.size,
    );
    if (_sized != child.size) {
      _sized = child.size;
      onSized(child.size);
    }
  }
}
