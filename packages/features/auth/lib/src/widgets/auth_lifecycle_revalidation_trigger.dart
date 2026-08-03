import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';

/// Dispatches [AuthSessionRevalidationRequested] when the app returns to
/// the foreground (#141) — the third revalidation trigger for a session
/// entered without server confirmation, after #98's connectivity edge and
/// periodic timer.
///
/// Canonical home for the resume-handling rationale; `AuthBloc` and the app
/// shell carry pointers here, not copies.
///
/// Neither existing trigger reliably covers a device **suspended offline
/// and resumed online**. The connectivity edge may never be observed —
/// `ConnectivityService` suppresses consecutive duplicate coarse states
/// (#9), and the platform stream can deliver nothing across a
/// suspend/resume boundary, so the app can wake up online having seen no
/// transition at all. The timer does cover it, but only on its own cadence:
/// the wrong latency for clearing a banner at the one moment the user is
/// guaranteed to be looking at it.
///
/// Renders [child] unchanged — no layout, no semantics, no localized
/// strings, so it adds nothing for a screen reader to announce or a
/// keyboard user to traverse.
///
/// ## Placement, and why the trigger is a widget
///
/// Must sit below a `BlocProvider<AuthBloc>`; the shell mounts it in the
/// auth `ShellRoute` subtree. Routes outside that subtree therefore get no
/// resume revalidation — accepted, tracked as #145.
///
/// That gap is **not** an artifact of using a widget. It is the bloc's
/// lifetime: the connectivity subscription is created in `AuthBloc`'s
/// constructor and cancelled in `close()`, and the periodic timer lives on
/// the same instance, so leaving the subtree closes the bloc and stops all
/// three triggers alike. Moving this listener into the bloc, or into an
/// injected lifecycle service, would relocate the gap rather than close it
/// — a service observing resume while the bloc is closed has nobody to
/// dispatch to. Closing it needs #145's route-placement decision, and the
/// altitude of this trigger should be revisited with it.
///
/// ## Dispatch is unconditional
///
/// This widget never reads `AuthBlocState`. `AuthBloc`'s handler already
/// no-ops unless the session is `SessionVerification.unverifiedOffline`,
/// and duplicating that guard here would give the eligibility rule two
/// places to drift. The handler is `droppable()`, so a resume coinciding
/// with a timer tick or connectivity edge cannot start a second concurrent
/// `getSession` — which matters, because resume also fires for brief
/// interruptions that end in refocus (notification shade, control centre,
/// app switcher peek). The ceiling stays at one lightweight GET per
/// completed attempt, and only while a session is unverified.
///
/// ## Only `onResume`
///
/// Not `onShow`, `onRestart`, `onInactive`, `onHide`, or `onPause`: one
/// return to the foreground emits several of those in a chain
/// (`onRestart` → `onShow` → `onResume`), so listening to more than one
/// multiplies dispatches for a single user-visible event. Accepted edge — a
/// platform that makes the app visible but never focused (iOS split view,
/// some desktop window states) stops at `inactive`, and the periodic timer
/// covers that window.
///
/// Uniform across platforms: [AppLifecycleListener] is Flutter SDK
/// everywhere, so there is nothing to gate and no platform package to leak.
/// On web the dispatch is inert regardless — web never enters an unverified
/// session (#98 D10; web parity is #144).
class AuthLifecycleRevalidationTrigger extends StatefulWidget {
  const AuthLifecycleRevalidationTrigger({required this.child, super.key});

  final Widget child;

  @override
  State<AuthLifecycleRevalidationTrigger> createState() =>
      _AuthLifecycleRevalidationTriggerState();
}

class _AuthLifecycleRevalidationTriggerState
    extends State<AuthLifecycleRevalidationTrigger> {
  /// [AppLifecycleListener] (Flutter 3.13+) rather than a raw
  /// [WidgetsBindingObserver]: it exposes the transition we care about as a
  /// named callback instead of a state switch, and seeds itself from
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
    // Defensive: [dispose] removes the observer, so this should be
    // unreachable after unmount. Guarded anyway because reading a disposed
    // element's context throws, and a lifecycle callback arriving during
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
