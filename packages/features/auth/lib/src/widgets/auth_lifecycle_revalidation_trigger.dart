import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';

/// Dispatches [AuthSessionRevalidationRequested] when the app returns to
/// the foreground (#141).
///
/// ## Why this exists
///
/// #98 gave `AuthBloc` two revalidation triggers for a session entered
/// without server confirmation: a `ConnectivityService` `offline → online`
/// edge, and a periodic retry timer that runs while the state is
/// unverified. Neither reliably covers a device **suspended offline and
/// resumed online**:
///
/// - The connectivity edge may never be observed. `ConnectivityService`
///   suppresses consecutive duplicate coarse states (#9), and the platform
///   stream may deliver nothing across a suspend/resume boundary — so the
///   app can wake up online having seen no transition at all.
/// - The periodic timer covers it eventually, but only on its own cadence,
///   and only because timers are still armed on resume. Waiting out an
///   interval to clear a banner the user is looking at *right now* is the
///   wrong latency for the one moment they are guaranteed to be watching.
///
/// This widget makes resume an explicit third trigger. It renders
/// [child] unchanged and adds no chrome.
///
/// ## Placement
///
/// Must sit below a `BlocProvider<AuthBloc>`; the app shell mounts it in
/// the auth `ShellRoute` subtree alongside the unverified-session banner
/// host. Consequence, accepted and tracked as #145: routes hosted *outside*
/// that shell (settings, feedback, create-household) mount neither this
/// trigger nor the bloc, so a resume there dispatches nothing. That is not
/// a regression — the periodic timer has exactly the same scope, since it
/// lives on the same bloc instance — and returning to the shell builds a
/// fresh bloc that runs a full session check anyway.
///
/// ## Dispatch is unconditional
///
/// This widget does not read `AuthBlocState`. `AuthBloc`'s handler already
/// no-ops unless the state is an authenticated session carrying
/// `SessionVerification.unverifiedOffline`, and duplicating that guard here
/// would create a second place for the eligibility rule to drift. A resume
/// while verified or signed out costs one inert event.
///
/// Overlap is handled by the bloc, not here: the handler is registered with
/// `droppable()`, so a resume that coincides with a connectivity edge or a
/// timer tick cannot start a second concurrent `getSession`. A resume also
/// fires for brief interruptions that end in refocus (notification shade,
/// control centre, app switcher peek); with the state guard and
/// `droppable()` in front of it, the ceiling is one lightweight GET per
/// completed attempt, and only while a session is unverified.
///
/// ## Only `onResume`
///
/// Not `onShow`, `onRestart`, `onInactive`, `onHide`, or `onPause`. A
/// return to the foreground emits several of these in one chain
/// (`onRestart` → `onShow` → `onResume`), so listening to more than one
/// would multiply dispatches for a single user-visible event.
///
/// Known, accepted edge: a platform that makes the app visible but never
/// focused (iOS split view, some desktop window states) stops at
/// `inactive`, and no revalidation fires until focus arrives. The periodic
/// timer covers that window.
///
/// ## Platforms
///
/// Uniform — [AppLifecycleListener] is Flutter SDK on every target, so
/// there is nothing to gate and no platform package to leak. On web the
/// callback maps to the visibility/focus model and the dispatch is inert
/// regardless, because web never enters an unverified session (#98 D10;
/// web parity is #144).
class AuthLifecycleRevalidationTrigger extends StatefulWidget {
  const AuthLifecycleRevalidationTrigger({required this.child, super.key});

  /// Rendered unchanged. This widget contributes no layout, no semantics,
  /// and no localized strings — it is a behavioural wrapper only, so it
  /// adds nothing for a screen reader to announce or a keyboard user to
  /// traverse.
  final Widget child;

  @override
  State<AuthLifecycleRevalidationTrigger> createState() =>
      _AuthLifecycleRevalidationTriggerState();
}

class _AuthLifecycleRevalidationTriggerState
    extends State<AuthLifecycleRevalidationTrigger> {
  /// [AppLifecycleListener] (Flutter 3.13+) rather than a raw
  /// [WidgetsBindingObserver]: it exposes the transition we care about as a
  /// named callback instead of a state switch, and it seeds itself from
  /// `WidgetsBinding.instance.lifecycleState` at construction — so mounting
  /// while the app is already resumed is not itself a transition and
  /// dispatches nothing.
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _onResume);
  }

  void _onResume() {
    // Defensive: [dispose] removes the observer, so this should not be
    // reachable after unmount. Guarded anyway because reading a disposed
    // element's context throws, and a lifecycle callback firing during
    // teardown is not worth crashing the app over.
    if (!mounted) return;
    context.read<AuthBloc>().add(const AuthSessionRevalidationRequested());
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
