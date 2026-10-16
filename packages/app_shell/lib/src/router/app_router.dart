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
  static const feedback = '/feedback';
  static const settings = '/settings';

  /// The household list (#269). Singular, consistent with
  /// [householdCreate] and with the reserved
  /// `/server/:serverId/household/:householdId/invite/:token` deep link.
  static const household = '/household';
  static const householdCreate = '$household/$_householdCreateSegment';

  /// One household, read-only (#270).
  ///
  /// This pattern and [householdCreate] **overlap**: `create` is a legal
  /// value for `:householdId`, so whichever is declared first wins the
  /// path `/household/create`. Create is declared first, and this is not a
  /// style preference — see the route table.
  ///
  /// Build a concrete location with [householdDetailOf] rather than
  /// interpolating: callers that hand-build the string are how a
  /// `:householdId` ends up URL-unsafe.
  static const householdDetail = '$household/$_householdDetailSegment';

  /// The id segment of [householdDetail].
  static const householdIdParam = 'householdId';

  // The two household children's paths relative to [household], which is
  // how the route table declares them (#308). The absolute constants above
  // are built from these, so the table and its callers cannot drift apart.
  static const _householdCreateSegment = 'create';
  static const _householdDetailSegment = ':$householdIdParam';

  /// The location of one household's detail screen.
  ///
  /// Ids are server- or client-assigned cuid2s, which are already
  /// path-safe; the encode is here for the id that one day is not.
  static String householdDetailOf(String householdId) =>
      '$household/${Uri.encodeComponent(householdId)}';

  /// The signed-in user's collection list (#44). Singular, like
  /// [household]. Not the reserved `/server/:serverId/collection/:userId`
  /// deep link, which names a server and a user; this is always the
  /// active session's own.
  static const collection = '/collection';

  /// The DataGateway admin list (#41).
  ///
  /// Under `/admin` because DataGateways belong to the admin dashboard
  /// (#274). When that lands it takes over the drawer entry and keeps this
  /// path.
  static const adminDataGateways = '/admin/data-gateways';

  /// The add form, beneath the list.
  static const dataGatewayAdd = '$adminDataGateways/$_dataGatewayAddSegment';

  /// The edit form for one DataGateway, beneath the list. Build a concrete
  /// location with [dataGatewayEditOf].
  ///
  /// No overlap with [dataGatewayAdd]: this pattern has two segments below
  /// the list, and that one has one.
  static const dataGatewayEdit = '$adminDataGateways/$_dataGatewayEditSegment';

  /// The id segment of [dataGatewayEdit].
  static const dataGatewayIdParam = 'dataGatewayId';

  static const _dataGatewayAddSegment = 'new';
  static const _dataGatewayEditSegment = ':$dataGatewayIdParam/edit';

  /// The location of one DataGateway's edit form.
  static String dataGatewayEditOf(String id) =>
      '$adminDataGateways/${Uri.encodeComponent(id)}/edit';

  static const error = '/error';

  /// The bootstrap-owned locations a ready app is bounced away from.
  /// `settings` is deliberately absent: it is a normal post-ready
  /// destination, not a bootstrap leg, so a ready app is not bounced off
  /// it (#120).
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
/// [AppRoutes.serverAdd] route. Always supplied by [BgeApp]; returns null
/// at navigation time when the composition cannot back the flow, in which
/// case the route falls back to the placeholder.
///
/// Null covers a partial root container (any of `WellKnownClient`,
/// `VersionNegotiator`, `ConnectivityService`, `BuildInfo` unregistered)
/// and an absent `ServerOrchestrator`. The whole set is checked, not a
/// representative member (#189): the orchestrator in particular is only
/// available once bootstrap has succeeded, so it cannot be settled when
/// the router is built. This is also the correct web behavior, where the
/// route is unreachable ([AppBootstrapNeedsServer] never occurs on web),
/// no `WellKnownClient` implementation exists, and the orchestrator is
/// null by design.
typedef ServerAddScreenBuilder = Widget? Function(BuildContext context);

/// Builds the real auth screen subtree (#37) for the [AppRoutes.auth]
/// route — the `AuthGate` rendered against the active server's bloc.
/// Always supplied by [BgeApp]; returns null at navigation time when no
/// active server is resolvable (web until #96, or a transient pre-active
/// state), in which case the route falls back to the placeholder.
typedef AuthScreenBuilder = Widget? Function(BuildContext context);

/// Builds the user-initiated feedback flow (#107) for the
/// [AppRoutes.feedback] route. Supplied by [BgeApp]; returns null at
/// navigation time when the root container carries no `FeedbackService`
/// (tests without a container; a platform composition that skipped
/// feedback wiring), in which case the route falls back to
/// [NotYetAvailableScreen].
///
/// The route sits **outside** the auth [ShellRoute]: the flow needs no
/// `AuthBloc` — submission goes through the device-global service, which
/// owns the send-or-queue decision. Reachability is still post-auth by
/// design (multi-server: a report must be attributable to a target
/// server): the redirect table only admits non-bootstrap locations once
/// [AppBootstrapReady].
typedef FeedbackScreenBuilder = Widget? Function(BuildContext context);

/// Builds the settings surface (#120) for the [AppRoutes.settings] route.
/// Supplied by [BgeApp]; returns null at navigation time when the
/// app-level settings controllers are not yet available (before the first
/// storage-ready bootstrap state, or a boot where hydrated storage was
/// unavailable), in which case the route falls back to
/// [NotYetAvailableScreen].
///
/// Like feedback, the route sits **outside** the auth [ShellRoute]
/// (settings needs no `AuthBloc`) and is reachable only once
/// [AppBootstrapReady] admits non-bootstrap locations. `settings` is not
/// in [AppRoutes.bootstrapLocations], so a ready app is not bounced away
/// from it.
typedef SettingsScreenBuilder = Widget? Function(BuildContext context);

/// Builds the create-household flow (#129) for the
/// [AppRoutes.householdCreate] route. Supplied by [BgeApp]; returns null at
/// navigation time when no active server is resolvable or its container
/// carries no `HouseholdRepository` / `SyncOperationSender` (tests without a
/// container; no active user session), in which case the route falls back
/// to [NotYetAvailableScreen]. Both platforms wire both halves in a real
/// session.
///
/// The route sits **outside** the auth [ShellRoute]: the screen needs no
/// `AuthBloc`, only the active server's scoped container. Reachability is
/// still post-auth — the redirect table only admits non-bootstrap
/// locations once [AppBootstrapReady] — and it is pushed from the household
/// list's FAB (#269) rather than deep-linked.
typedef CreateHouseholdScreenBuilder = Widget? Function(BuildContext context);

/// Builds the household list (#269) for the [AppRoutes.household] route.
/// Supplied by [BgeApp]; returns null at navigation time when no active
/// server is resolvable or its container carries no `HouseholdRepository`
/// (tests without a container; no active user session on either platform,
/// since #137 gave web the same user tier), in which case the route falls
/// back to [NotYetAvailableScreen].
///
/// Guarded on the repository **alone**, unlike
/// [CreateHouseholdScreenBuilder]: the list reads the local cache and needs
/// no way to send (#269). Where the `SyncOperationSender` is missing the
/// list still renders — it simply offers no create affordance.
///
/// Sits outside the auth [ShellRoute] for the same reason the create route
/// does: it needs the active server's scoped container, not an `AuthBloc`.
typedef HouseholdListScreenBuilder = Widget? Function(BuildContext context);

/// Builds one household's detail screen (#270) for the
/// [AppRoutes.householdDetail] route, given the `:householdId` the path
/// carried. Supplied by [BgeApp]; returns null on the same conditions as
/// [HouseholdListScreenBuilder] — no resolvable server, or a container
/// with no `HouseholdRepository` — in which case the route falls back to
/// [NotYetAvailableScreen].
///
/// Guarded on the repository **alone**, like the list and unlike create
/// (#269 D4): this screen reads the local cache and never calls the
/// server, so a missing `HouseholdRemoteDataSource` costs it nothing.
///
/// The id reaches the builder unvalidated — any string that fits one path
/// segment. The screen answers an unreadable id with its not-found state,
/// which is the same answer the repository's membership gate gives, so
/// there is nothing for the route layer to check.
typedef HouseholdDetailScreenBuilder = Widget? Function(
  BuildContext context,
  String householdId,
);

/// Builds the collection list (#44) for the [AppRoutes.collection] route.
/// Supplied by [BgeApp]; returns null at navigation time when no active
/// server is resolvable or its container carries no
/// `GameCollectionRepository` (tests without a container; no active user
/// session), in which case the route falls back to [NotYetAvailableScreen].
///
/// Guarded on the repository alone, like the household list: the list reads
/// the local cache, and a missing hydrate costs it only the retry.
///
/// Sits outside the auth [ShellRoute] for the household list's reason: it
/// needs the active server's scoped container, not an `AuthBloc`.
typedef CollectionListScreenBuilder = Widget? Function(BuildContext context);

/// Builds the DataGateway admin list (#41) for the
/// [AppRoutes.adminDataGateways] route. Supplied by [BgeApp]; returns null
/// when no active server is resolvable or its container carries no
/// `DataGatewayRemoteDataSource`, in which case the route falls back to
/// [NotYetAvailableScreen].
///
/// Not gated on the user's access. A deep link by a user the server refuses
/// reaches the screen, which says they have no access; hiding the route
/// would answer the same question with a less useful page.
typedef DataGatewayListScreenBuilder = Widget? Function(BuildContext context);

/// Builds the DataGateway add form, or the edit form for [dataGatewayId]
/// (#41). Null [dataGatewayId] is the add form. Same null contract as
/// [DataGatewayListScreenBuilder].
typedef DataGatewayFormScreenBuilder = Widget? Function(
  BuildContext context,
  String? dataGatewayId,
);

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
  FeedbackScreenBuilder? feedbackBuilder,
  SettingsScreenBuilder? settingsBuilder,
  CreateHouseholdScreenBuilder? createHouseholdBuilder,
  HouseholdListScreenBuilder? householdListBuilder,
  HouseholdDetailScreenBuilder? householdDetailBuilder,
  CollectionListScreenBuilder? collectionListBuilder,
  DataGatewayListScreenBuilder? dataGatewayListBuilder,
  DataGatewayFormScreenBuilder? dataGatewayFormBuilder,
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
            // Home is only reached once [AppBootstrapReady] (post-auth,
            // active server present), so homeBuilder returns null only in a
            // transient/defensive pre-active state. Falls back to
            // [NotYetAvailableScreen]: static (so widget tests settle —
            // a spinner would hang pumpAndSettle) and consistent with the
            // other optional-builder routes (feedback / settings /
            // householdCreate). The home placeholder is retired (#129).
            builder: (context, _) =>
                homeBuilder?.call(context) ?? const NotYetAvailableScreen(),
          ),
        ],
      ),
      // #107: user-initiated feedback. Outside the auth ShellRoute (no
      // AuthBloc needed — see [FeedbackScreenBuilder]); reachable only
      // when [AppBootstrapReady] admits non-bootstrap locations.
      GoRoute(
        path: AppRoutes.feedback,
        builder: (context, _) =>
            feedbackBuilder?.call(context) ?? const NotYetAvailableScreen(),
      ),
      // #120: user settings. Outside the auth ShellRoute (no AuthBloc
      // needed — see [SettingsScreenBuilder]); reachable only when
      // [AppBootstrapReady] admits non-bootstrap locations, and not
      // bounced (settings is not a bootstrap location).
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, _) =>
            settingsBuilder?.call(context) ?? const NotYetAvailableScreen(),
      ),
      // ── The household routes: why they nest, and why their order matters ──
      //
      // `/household/create` (#129) and `/household/:householdId` (#270) are
      // children of `/household` (#269), not its siblings (#308). A `go` to
      // either therefore builds the list beneath it, so there is always
      // something to go back to — which is what lets the detail screen's
      // way back be a plain pop. A `push` still adds only the leaf page, so
      // the drawer path keeps home beneath the list.
      //
      // Order among the children is the part that cannot change. `create`
      // is a perfectly legal `:householdId`, so `/household/create` matches
      // BOTH children. go_router takes the first declared match, so create
      // must come first or the create flow silently becomes a detail screen
      // for a household nobody can have.
      //
      // The detail screen also answers a literal `create` id with its
      // not-found state (#270 D6). That is the belt to this ordering's
      // braces — cheap, and it keeps the failure legible if these are ever
      // reordered.
      GoRoute(
        path: AppRoutes.household,
        builder: (context, _) =>
            householdListBuilder?.call(context) ??
            const NotYetAvailableScreen(),
        routes: [
          // #129: create-household flow. Outside the auth ShellRoute (needs
          // no AuthBloc — only the active server's container; see
          // [CreateHouseholdScreenBuilder]). Reachable only once
          // [AppBootstrapReady] admits non-bootstrap locations; pushed from
          // the list screen's FAB (#269).
          //
          // MUST stay declared above the detail route — see the block above.
          GoRoute(
            path: AppRoutes._householdCreateSegment,
            builder: (context, _) =>
                createHouseholdBuilder?.call(context) ??
                const NotYetAvailableScreen(),
          ),
          // #270: one household, read-only. Pushed from a list row, and
          // where the reserved invite deep link eventually lands — which is
          // why the id-addressed route exists now rather than later.
          GoRoute(
            path: AppRoutes._householdDetailSegment,
            builder: (context, state) {
              final id = state.pathParameters[AppRoutes.householdIdParam] ?? '';
              return householdDetailBuilder?.call(context, id) ??
                  const NotYetAvailableScreen();
            },
          ),
        ],
      ),
      // #44: the collection list. Outside the auth ShellRoute (no AuthBloc
      // needed; see [CollectionListScreenBuilder]), pushed from the home
      // drawer, and reachable only once [AppBootstrapReady] admits
      // non-bootstrap locations. A top-level destination is #414's.
      GoRoute(
        path: AppRoutes.collection,
        builder: (context, _) =>
            collectionListBuilder?.call(context) ??
            const NotYetAvailableScreen(),
      ),
      // #41: the DataGateway admin screens. The forms are children of the
      // list, as the household children are of theirs (#308), so a deep link
      // to a form builds the list beneath it and leaving the form is a plain
      // pop.
      GoRoute(
        path: AppRoutes.adminDataGateways,
        builder: (context, _) =>
            dataGatewayListBuilder?.call(context) ??
            const NotYetAvailableScreen(),
        routes: [
          GoRoute(
            path: AppRoutes._dataGatewayAddSegment,
            builder: (context, _) =>
                dataGatewayFormBuilder?.call(context, null) ??
                const NotYetAvailableScreen(),
          ),
          GoRoute(
            path: AppRoutes._dataGatewayEditSegment,
            builder: (context, state) {
              final id =
                  state.pathParameters[AppRoutes.dataGatewayIdParam] ?? '';
              return dataGatewayFormBuilder?.call(context, id) ??
                  const NotYetAvailableScreen();
            },
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

/// Builds the real home screen subtree for the [AppRoutes.home] route —
/// the navigation-drawer menu (#129). Always supplied by [BgeApp] so the
/// menu's sign-out entry can reach the active server's auth bloc; returns
/// null at navigation time when no active server backs the bloc (a
/// transient pre-active state), in which case the route falls back to
/// [NotYetAvailableScreen], like the other optional-builder routes.
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
