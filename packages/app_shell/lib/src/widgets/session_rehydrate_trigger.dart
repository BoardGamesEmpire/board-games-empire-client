import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';

import 'detached_rehydrate.dart';

/// Asks the active session's [SessionRehydrator] for a pass when something
/// suggests the server is worth trying again (#302 D1).
///
/// A session that activates while the server is unreachable used to have
/// no route back: `hydrate()` had exactly one call site, so the client
/// never asked again for the life of that session and the user's only fix
/// was signing out and in. This is the general trigger; the caches
/// register themselves (#302 D2), so nothing here knows what a household
/// is.
///
/// ## Why the trigger is composed here
///
/// Not in the session scope, where the hydrates live: each `ServerContext`
/// wraps its own GetIt instance and resolution never falls through to the
/// root container, so the root-owned [ConnectivityService] is not
/// resolvable from a per-user service. The shell is where both halves are
/// already in hand.
///
/// **Above the router, not inside a route.** The screens that read a
/// re-hydrated cache — the household list and detail — are top-level
/// routes *outside* the auth `ShellRoute`, so a trigger mounted in that
/// shell would be unmounted on exactly the screen showing "couldn't
/// refresh" (a `go` to `/household` drops the shell page; a deep link
/// there never builds it). It therefore lives in the `MaterialApp.router`
/// builder, which wraps the Navigator and survives every route change.
/// That placement is also why the scope arrives as [scopeSource] rather
/// than as a container: a `StreamBuilder` above the Navigator would change
/// the tree shape as servers came and went and remount the whole app under
/// it, and a scope captured at build time would be the null the bootstrap
/// had not yet replaced. Reading it per trigger is the same shape
/// `ActiveServerFeedbackTargetResolver` uses, for the same reason.
///
/// ## Two triggers, and what they do not cover
///
/// **A connectivity edge**, and **app resume** — the pair #98/#141 already
/// established for auth revalidation, for the same reason. The edge alone
/// misses a device suspended offline and resumed online: `ConnectivityService`
/// suppresses consecutive duplicate coarse states (#9), and the platform
/// stream can deliver nothing across a suspend/resume boundary, so the app
/// can wake up online having observed no transition at all.
///
/// Together they still leave three cases with no in-app trigger, all of
/// them the same shape — the transport never changed, so the coarse state
/// never changed:
///
/// - a **server-only outage**: connectivity reports device transport, not
///   reachability, so a server that is down while the device stays online
///   produces no edge, and a foregrounded app never resumes. This is
///   precisely the run #302 was filed from;
/// - a **transport switch inside `online`** — a dead-uplink Wi-Fi giving
///   way to cellular is `online → online`, suppressed as a duplicate (#9),
///   even though it is the moment the request would start working;
/// - an edge **consumed by a still-running pass**: a drain hanging on a
///   socket timeout is not stale (#302 D4), so the trigger is dropped, and
///   the pass then fails with nothing left to re-trigger it.
///
/// #300's manual retry is the answer for all three today. #311 is the
/// bounded retry that would cover them without the user, which is why it
/// is scoped to a *failed pass* rather than to any particular trigger.
///
/// ## What gates a pass
///
/// Nothing here. The registry lives in the user-session scope, so its
/// absence **is** "no session is active": after sign-out there is nothing
/// registered to resolve, and #302's "no re-run without an active session"
/// rule holds without a second gate to keep in step with the first.
///
/// Renders [child] unchanged — no layout, no semantics, no strings.
class SessionRehydrateTrigger extends StatefulWidget {
  const SessionRehydrateTrigger({
    required this.scopeSource,
    required this.child,
    this.connectivity,
    super.key,
  });

  /// Resolves the active-server scope **at trigger time**.
  ///
  /// A function rather than a scope: `AppBootstrapCubit` publishes the
  /// scope only once bootstrap succeeds, which is after this widget is
  /// first built, so a captured value would be null for the life of the
  /// app. Returning null — no orchestration (web until #96), or no active
  /// server yet — simply means there is nothing to re-hydrate.
  ///
  /// Resolution through the active server's container falls through to the
  /// user-session scope, which is where the rehydrator is registered.
  final ActiveServerScope? Function() scopeSource;

  /// Device-global connectivity from the root container. Null on
  /// compositions without it (#98's shape), which leaves resume as the
  /// only trigger rather than disabling the widget.
  final ConnectivityService? connectivity;

  final Widget child;

  @override
  State<SessionRehydrateTrigger> createState() =>
      _SessionRehydrateTriggerState();
}

class _SessionRehydrateTriggerState extends State<SessionRehydrateTrigger> {
  StreamSubscription<ConnectivityState>? _connectivitySubscription;

  /// Same choice as `AuthLifecycleRevalidationTrigger`: [AppLifecycleListener]
  /// seeds itself from the current lifecycle state, so mounting while the
  /// app is already resumed is not a transition and fires nothing.
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _onResume);
    _connectivitySubscription = widget.connectivity
        ?.watch()
        // The first element is the replay of the current state, not a
        // change (`watch` is a BehaviorSubject). Treating it as an edge
        // would re-hydrate on every mount and every server switch —
        // neither of which is connectivity returning.
        .skip(1)
        .where((state) => state == ConnectivityState.online)
        .listen((_) => _rehydrate('connectivity'));
  }

  void _onResume() {
    // Defensive: dispose() drops the listener, so this should be
    // unreachable after unmount. Reading a disposed element's state is not
    // worth crashing the app over.
    if (!mounted) return;
    _rehydrate('resume');
  }

  /// Fire-and-forget, through the shared guard both of the shell's
  /// re-hydrate callers use: no caller is waiting, and the pass reports
  /// what it achieved through each cache's own status holder.
  ///
  /// Overlapping triggers are the registry's problem, not this widget's —
  /// a pass arriving while one is in flight joins it (#302 D3), so a
  /// flapping connection cannot fan out into concurrent drains.
  ///
  /// The scope is read **per trigger** rather than captured: see the class
  /// doc on [SessionRehydrateTrigger.scopeSource]. A container disposed
  /// between the last active-server event and this callback refuses use, so
  /// resolution belongs inside the guard — which is where
  /// [startDetachedRehydrate] runs it.
  void _rehydrate(String reason) => startDetachedRehydrate(
    trigger: reason,
    resolve: () {
      final container = widget.scopeSource()?.active?.container;
      if (container == null) return null;
      return container.isRegistered<SessionRehydrator>()
          ? container.get<SessionRehydrator>()
          : null;
    },
  );

  @override
  void dispose() {
    unawaited(_connectivitySubscription?.cancel());
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
