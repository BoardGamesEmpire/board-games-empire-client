import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../bootstrap/app_bootstrap_cubit.dart';
import '../bootstrap/app_bootstrap_state.dart';
import '../screens/bootstrap_error_screen.dart';
import '../screens/not_yet_available_screen.dart';
import '../screens/shell_placeholder_screen.dart';
import '../screens/splash_screen.dart';

/// Shell route locations.
abstract final class AppRoutes {
  static const splash = '/';
  static const serverAdd = '/server-add';
  static const auth = '/auth';
  static const home = '/home';
  static const error = '/error';

  /// The bootstrap-owned locations a ready app is bounced away from.
  static const bootstrapLocations = {splash, error, serverAdd, auth};
}

/// Reserved deep-link resource path patterns (#10), declared from day one
/// so the URL scheme is stable before any UI exists behind it. On native
/// these arrive via `bge://server/{serverId}/...`; on web they are plain
/// path URLs. Web is single-server (same-origin), so its `:serverId`
/// segment is validated rather than used for switching — that logic lands
/// with #10.
const reservedDeepLinkPathPatterns = <String>[
  '/server/:serverId/household/:householdId/invite/:token',
  '/server/:serverId/event/:eventId',
  '/server/:serverId/event/:eventId/rsvp/:token',
  '/server/:serverId/game/:gameId',
  '/server/:serverId/collection/:userId',
];

/// Builds the real server-add screen subtree (#36) for the
/// [AppRoutes.serverAdd] route. Supplied by [BgeApp] when the root
/// container carries the onboarding services (native); when null the
/// pre-#36 placeholder is kept — which is also the correct web behavior,
/// where the route is unreachable ([AppBootstrapNeedsServer] never
/// occurs on web) and no `WellKnownClient` implementation exists.
typedef ServerAddScreenBuilder = Widget Function(BuildContext context);

/// Builds the real auth screen subtree (#37) for the [AppRoutes.auth]
/// route — the `AuthGate` rendered against the active server's bloc.
/// Always supplied by [BgeApp]; returns null at navigation time when no
/// active server is resolvable (web until #96, or a transient pre-active
/// state), in which case the route falls back to the placeholder.
typedef AuthScreenBuilder = Widget? Function(BuildContext context);

/// Builds the application router.
///
/// Redirects are driven entirely by [bootstrapCubit]'s state: while
/// bootstrap is unresolved every location is forced to the state's route
/// (deep links included — queueing them for post-auth resumption is #10's
/// scope). Once ready, bootstrap-owned locations bounce to home and the
/// reserved deep-link paths resolve (to [NotYetAvailableScreen] until real
/// features land). #37 feeds authenticated-session state into this same
/// seam by emitting [AppBootstrapReady] / [AppBootstrapNeedsAuth].
GoRouter buildAppRouter({
  required AppBootstrapCubit bootstrapCubit,
  required BootstrapStreamListenable refreshListenable,
  ServerAddScreenBuilder? serverAddBuilder,
  AuthScreenBuilder? authBuilder,
  HomeScreenBuilder? homeBuilder,
  AuthScopeBuilder? authScopeBuilder,
}) {
  return GoRouter(
    initialLocation: AppRoutes.splash,
    // go_router removes its listener on dispose but never disposes the
    // listenable itself. It is therefore a required parameter: the caller
    // owns it and must dispose it (after the router). There is deliberately
    // no internally-constructed fallback — that would be a subscription no
    // caller could dispose.
    refreshListenable: refreshListenable,
    redirect: (context, routerState) {
      final location = routerState.matchedLocation;
      return switch (bootstrapCubit.state) {
        AppBootstrapInitializing() =>
          location == AppRoutes.splash ? null : AppRoutes.splash,
        AppBootstrapFailed() =>
          location == AppRoutes.error ? null : AppRoutes.error,
        AppBootstrapNeedsServer() =>
          location == AppRoutes.serverAdd ? null : AppRoutes.serverAdd,
        AppBootstrapNeedsAuth() =>
          location == AppRoutes.auth ? null : AppRoutes.auth,
        AppBootstrapReady() =>
          AppRoutes.bootstrapLocations.contains(location)
              ? AppRoutes.home
              : null,
      };
    },
    routes: [
      GoRoute(path: AppRoutes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: AppRoutes.serverAdd,
        // Real server-add UI (#36) when the shell supplied a builder;
        // the placeholder otherwise (tests, web).
        builder: (context, _) =>
            serverAddBuilder?.call(context) ??
            const ShellPlaceholderScreen(kind: ShellPlaceholderKind.serverAdd),
      ),
      // #37: the auth and home routes share ONE AuthBloc, provided by
      // [authScopeBuilder] inside the router subtree — go_router builds
      // route widgets under its own Navigator, which does not inherit
      // providers placed above the router's widget, so the provider must
      // live here (a ShellRoute), not app-level. The shell's scope builder
      // creates the keyed provider + drives the bootstrap gate from the
      // bloc's terminal auth states; a single instance survives the
      // auth → home transition. When no scope builder is supplied (tests
      // without a scope, web until #96) the child renders bare and the
      // route builders fall back to their placeholders.
      ShellRoute(
        builder: (context, state, child) =>
            authScopeBuilder?.call(context, child) ?? child,
        routes: [
          GoRoute(
            path: AppRoutes.auth,
            builder: (context, _) =>
                authBuilder?.call(context) ??
                const ShellPlaceholderScreen(kind: ShellPlaceholderKind.auth),
          ),
          GoRoute(
            path: AppRoutes.home,
            builder: (context, _) =>
                homeBuilder?.call(context) ??
                const ShellPlaceholderScreen(kind: ShellPlaceholderKind.home),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.error,
        builder: (_, _) => BlocBuilder<AppBootstrapCubit, AppBootstrapState>(
          bloc: bootstrapCubit,
          builder: (context, state) {
            final failed = state is AppBootstrapFailed ? state : null;
            return BootstrapErrorScreen(
              canOfferReset: failed?.canOfferReset ?? false,
              onRetry: () => unawaited(bootstrapCubit.retry()),
              onReset: () => unawaited(bootstrapCubit.resetAndRetry()),
            );
          },
        ),
      ),
      for (final pattern in reservedDeepLinkPathPatterns)
        GoRoute(
          path: pattern,
          builder: (_, _) => const NotYetAvailableScreen(),
        ),
    ],
  );
}

/// Builds the real home screen subtree for the [AppRoutes.home] route.
/// Always supplied by [BgeApp] so the temporary sign-out control (#37) can
/// reach the active server's auth bloc; returns null at navigation time
/// when no active server backs the bloc, falling back to the placeholder.
typedef HomeScreenBuilder = Widget? Function(BuildContext context);

/// Wraps the auth+home [ShellRoute] child with the active server's
/// `AuthBloc` provider and the bootstrap-gate listener (#37). Supplied by
/// [BgeApp]; when null the child renders bare (tests without a scope, web
/// until #96) and the route builders fall back to placeholders.
///
/// Lives at the router layer because go_router builds route widgets under
/// its own Navigator, which does not inherit providers placed above the
/// router — so the provider must be inside the route subtree, not
/// app-level.
typedef AuthScopeBuilder = Widget Function(BuildContext context, Widget child);

/// Adapts the cubit's state stream to the [Listenable] that go_router uses
/// to re-evaluate redirects.
///
/// Ownership: go_router never disposes its `refreshListenable`, so whoever
/// creates this must [dispose] it — after disposing the router, which
/// still removes its listener during its own dispose. No `onDone` cleanup
/// is needed or wanted: a completed subscription is inert (nothing left to
/// cancel), and referencing the late subscription field from inside the
/// `listen` call would race streams that complete synchronously.
class BootstrapStreamListenable extends ChangeNotifier {
  BootstrapStreamListenable(Stream<Object?> stream) {
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<Object?> _subscription;

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
