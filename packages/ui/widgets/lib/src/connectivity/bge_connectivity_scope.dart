import 'package:flutter/widgets.dart';

/// What the window knows about connectivity, for the controls below it (#49).
///
/// Presentation-only: the host decides when "offline" is real (it debounces
/// the service) and passes the result in, with the localized reason, so this
/// package keeps no connectivity or localization dependency.
///
/// Every lookup falls back to online, so a widget pumped without a scope
/// behaves as it did before the scope existed.
///
/// Each lookup depends on its own part of the state, so the end of the
/// strip's "Back online" hold rebuilds what reads [noticeShowing] and not
/// every gated control on screen.
class BgeConnectivityScope extends InheritedModel<Object> {
  const BgeConnectivityScope({
    required this.offline,
    required this.noticeShowing,
    required this.onlineOnlyReason,
    required super.child,
    super.key,
  });

  /// The debounced state controls read. False again the moment the
  /// connection returns, even while the strip still says "Back online".
  final bool offline;

  /// Whether the strip is on screen, its "Back online" hold included.
  final bool noticeShowing;

  /// Localized reason a direct-write control is unavailable offline.
  final String onlineOnlyReason;

  static BgeConnectivityScope? _of(BuildContext context, _Aspect aspect) =>
      InheritedModel.inheritFrom<BgeConnectivityScope>(context, aspect: aspect);

  /// Whether to treat the connection as lost; false with no scope.
  static bool offlineOf(BuildContext context) =>
      _of(context, _Aspect.offline)?.offline ?? false;

  /// Whether the strip is on screen; false with no scope.
  static bool noticeShowingOf(BuildContext context) =>
      _of(context, _Aspect.notice)?.noticeShowing ?? false;

  /// The reason to give a disabled control, or null unless offline.
  static String? onlineOnlyReasonOf(BuildContext context) {
    final scope = _of(context, _Aspect.offline);
    return scope != null && scope.offline ? scope.onlineOnlyReason : null;
  }

  @override
  bool updateShouldNotify(BgeConnectivityScope oldWidget) =>
      _offlineChanged(oldWidget) || noticeShowing != oldWidget.noticeShowing;

  @override
  bool updateShouldNotifyDependent(
    BgeConnectivityScope oldWidget,
    Set<Object> dependencies,
  ) =>
      (dependencies.contains(_Aspect.offline) && _offlineChanged(oldWidget)) ||
      (dependencies.contains(_Aspect.notice) &&
          noticeShowing != oldWidget.noticeShowing);

  bool _offlineChanged(BgeConnectivityScope oldWidget) =>
      offline != oldWidget.offline ||
      onlineOnlyReason != oldWidget.onlineOnlyReason;
}

/// The parts of [BgeConnectivityScope] a widget can depend on.
enum _Aspect {
  /// [BgeConnectivityScope.offline] and the reason that goes with it.
  offline,

  /// [BgeConnectivityScope.noticeShowing].
  notice,
}
