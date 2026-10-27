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

  /// One household's open invites (#455), beneath its detail screen. Build
  /// a concrete location with [householdInvitesOf].
  static const householdInvites = '$householdDetail/$_householdInvitesSegment';

  /// The form for inviting someone to one household (#455), beneath its
  /// detail screen beside its invites (#569), since a member may send but
  /// can't read the invites. Build a concrete location with
  /// [householdInviteSendOf].
  static const householdInviteSend =
      '$householdDetail/$_householdInviteSendSegment';

  static const _householdInvitesSegment = 'invites';
  static const _householdInviteSendSegment = 'invite';

  /// The form for editing one household (#476), beneath its detail screen.
  /// Build a concrete location with [householdEditOf].
  static const householdEdit = '$householdDetail/$_householdEditSegment';

  static const _householdEditSegment = 'edit';

  /// The location of one household's invites.
  static String householdInvitesOf(String householdId) =>
      '${householdDetailOf(householdId)}/$_householdInvitesSegment';

  /// The location of one household's send-invite form.
  static String householdInviteSendOf(String householdId) =>
      '${householdDetailOf(householdId)}/$_householdInviteSendSegment';

  /// The location of one household's edit form.
  static String householdEditOf(String householdId) =>
      '${householdDetailOf(householdId)}/$_householdEditSegment';

  /// The invites sent to the current user (#455). Top-level: the inbox
  /// spans every household, so it belongs under none of them.
  static const invites = '/invites';

  /// The invites the current user sent (#487). Under the inbox, because it
  /// is reached from there.
  static const invitesSent = '/invites/sent';

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

  /// The server's games, to browse (#42). Plural, unlike [household] and
  /// [collection]: it lists the catalog, not one thing the user has. Not the
  /// reserved `/server/:serverId/game/:gameId` deep link, which names a
  /// server; that stays reserved until #10 can tell whose server it names.
  static const games = '/games';

  /// Search, beneath [games] (#42).
  ///
  /// This pattern and [gameDetail] **overlap**: `search` is a legal value
  /// for `:gameId`, so search is declared first, as household create is.
  static const gameSearch = '$games/$_gameSearchSegment';

  /// One game, beneath [games] (#42). Build a concrete location with
  /// [gameDetailOf].
  static const gameDetail = '$games/$_gameDetailSegment';

  /// The id segment of [gameDetail].
  static const gameIdParam = 'gameId';

  static const _gameSearchSegment = 'search';
  static const _gameDetailSegment = ':$gameIdParam';

  /// The location of one game's detail screen.
  static String gameDetailOf(String gameId) =>
      '$games/${Uri.encodeComponent(gameId)}';

  /// The signed-in user's events overview (#497). Plural, like [games]: it
  /// lists many events, not one thing the user has. Not the reserved
  /// `/server/:serverId/event/:eventId` deep link, which names a server.
  static const events = '/events';

  /// The segments of the group pages beneath [events], one per group the
  /// overview shows (#497), in its order. Each is the group's `EventGroup`
  /// name, which is how the shell maps one back to its group.
  ///
  /// These and the `:eventId` detail beneath [events] (#498, [eventDetail])
  /// **overlap**: `upcoming` is a legal event id, so the group pages are
  /// declared first and the detail after them, as game search is before the
  /// game detail.
  static const eventGroupSegments = <String>['upcoming', 'planning', 'past'];

  /// The location of the group page named [segment], one of
  /// [eventGroupSegments].
  static String eventGroupOf(String segment) => '$events/$segment';

  /// The form for creating an event (#499), beneath [events]. Build a
  /// location that starts it in a household with [eventCreateOf].
  ///
  /// This pattern and [eventDetail] **overlap** too: `create` is a legal
  /// event id, so the form is declared before the detail, as the group pages
  /// are.
  static const eventCreate = '$events/$_eventCreateSegment';

  /// The query parameter of [eventCreate] naming the household the form
  /// starts in. An empty value names none.
  static const eventCreateHouseholdParam = 'household';

  static const _eventCreateSegment = 'create';

  /// The location of the create form, starting in [householdId] where one is
  /// given.
  ///
  /// A household id is a query value here, not a path segment, so it is
  /// encoded as one.
  static String eventCreateOf({String? householdId}) => householdId == null
      ? eventCreate
      : Uri(
          path: eventCreate,
          queryParameters: {eventCreateHouseholdParam: householdId},
        ).toString();

  /// One event, beneath [events] (#498). Build a concrete location with
  /// [eventDetailOf].
  static const eventDetail = '$events/$_eventDetailSegment';

  /// The id segment of [eventDetail].
  static const eventIdParam = 'eventId';

  static const _eventDetailSegment = ':$eventIdParam';

  /// The location of one event's detail screen.
  ///
  /// Ids are path-safe in practice, as [householdDetailOf]'s are; the encode
  /// is here for the id that one day is not.
  static String eventDetailOf(String eventId) =>
      '$events/${Uri.encodeComponent(eventId)}';

  /// The changes that couldn't sync, each with a retry and a discard
  /// (#190). Always the active session's own, like [collection].
  static const stuckChanges = '/stuck-changes';

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
/// active server is resolvable (a transient pre-active state), in which
/// case the route falls back to the placeholder.
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
/// server to show itself, so a missing `HouseholdRemoteDataSource` costs it
/// nothing. The invite, edit and member actions it offers (#455, #476, #480)
/// do call the server, and each is left out where its client is not
/// registered.
///
/// The id reaches the builder unvalidated — any string that fits one path
/// segment. The screen answers an unreadable id with its not-found state,
/// which is the same answer the repository's membership gate gives, so
/// there is nothing for the route layer to check.
typedef HouseholdDetailScreenBuilder = Widget? Function(
  BuildContext context,
  String householdId,
);

/// Builds the invite inbox (#455) for the [AppRoutes.invites] route.
/// Supplied by [BgeApp]; returns null when no active server is resolvable
/// or its container lacks the `HouseholdInviteRemoteDataSource`, in which
/// case the route falls back to [NotYetAvailableScreen].
typedef InviteInboxScreenBuilder = Widget? Function(BuildContext context);

/// Builds the invites the current user sent (#487) for the
/// [AppRoutes.invitesSent] route. Supplied by [BgeApp]; same null contract
/// as [InviteInboxScreenBuilder], so the two routes are available together.
typedef SentInvitesScreenBuilder = Widget? Function(BuildContext context);

/// Builds one household's invites (#455) for the
/// [AppRoutes.householdInvites] route, given the `:householdId` the path
/// carried. Same null contract as [InviteInboxScreenBuilder], and also null
/// without a `HouseholdRepository`, which says who is looking.
///
/// Not gated on the viewer's role. A deep link by someone the server
/// refuses reaches the screen, which says only owners and admins can see
/// the invites.
typedef HouseholdInvitesScreenBuilder = Widget? Function(
  BuildContext context,
  String householdId,
);

/// Builds the send-invite form for one household (#455) for the
/// [AppRoutes.householdInviteSend] route. Same null contract as
/// [HouseholdInvitesScreenBuilder], and also null without the
/// `UserRemoteDataSource` the form's person search asks (#499).
typedef SendHouseholdInviteScreenBuilder = Widget? Function(
  BuildContext context,
  String householdId,
);

/// Builds the edit form for one household (#476) for the
/// [AppRoutes.householdEdit] route. Same null contract as
/// [HouseholdInvitesScreenBuilder], with the per-server
/// `HouseholdRemoteDataSource` the save is sent through in place of the
/// invite client.
///
/// Not gated on the viewer's role. A deep link by someone who may not edit
/// reaches the screen, which says only owners and admins can.
typedef EditHouseholdScreenBuilder = Widget? Function(
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

/// Builds the game browse screen (#42) for the [AppRoutes.games] route.
/// Supplied by [BgeApp]; returns null at navigation time when no active
/// server is resolvable or its container carries no `GamesRemoteDataSource`,
/// in which case the route falls back to [NotYetAvailableScreen].
///
/// Guarded on the remote alone: the games cache is optional, and without it
/// the screen still reads the server, with nothing to show offline.
typedef GameBrowseScreenBuilder = Widget? Function(BuildContext context);

/// Builds the game search screen (#42) for the [AppRoutes.gameSearch]
/// route. Same null contract as [GameBrowseScreenBuilder].
typedef GameSearchScreenBuilder = Widget? Function(BuildContext context);

/// Builds one game's detail screen (#42) for the [AppRoutes.gameDetail]
/// route, given the `:gameId` the path carried. Same null contract as
/// [GameBrowseScreenBuilder].
///
/// The id reaches the builder unvalidated. The screen answers one that
/// cannot name a game with its unavailable state.
typedef GameDetailScreenBuilder = Widget? Function(
  BuildContext context,
  String gameId,
);

/// Builds the events overview (#497) for the [AppRoutes.events] route.
/// Supplied by [BgeApp]; returns null at navigation time when no active
/// server is resolvable or its container carries no `EventRepository`
/// (tests without a container; no active user session), in which case the
/// route falls back to [NotYetAvailableScreen].
///
/// Guarded on the repository alone, like the collection list: the overview
/// reads the local cache, and a missing hydrate costs it only the retry.
typedef EventOverviewScreenBuilder = Widget? Function(BuildContext context);

/// Builds one group's page (#497) for a route beneath [AppRoutes.events],
/// given its segment, one of [AppRoutes.eventGroupSegments]. Same null
/// contract as [EventOverviewScreenBuilder], and null too for a segment that
/// names no group.
typedef EventGroupScreenBuilder = Widget? Function(
  BuildContext context,
  String segment,
);

/// Builds the create form (#499) for the [AppRoutes.eventCreate] route,
/// given the household its `?household=` query names, or null where it names
/// none. Supplied by [BgeApp]; returns null at navigation time when no active
/// server is resolvable or its container lacks the `EventRepository`, the
/// `SyncOperationSender` the create is sent through, or the
/// `UserRemoteDataSource` its invitee search reads, in which case the route
/// falls back to [NotYetAvailableScreen].
///
/// The household reaches the builder unchecked. The form starts in it only
/// if it is among the households the user may create an event in.
typedef EventCreateScreenBuilder = Widget? Function(
  BuildContext context,
  String? householdId,
);

/// Builds one event's detail screen (#498) for the [AppRoutes.eventDetail]
/// route, given the `:eventId` the path carried. Same null contract as
/// [EventOverviewScreenBuilder].
///
/// The id reaches the builder unvalidated. The screen answers one that names
/// no event with its not-found state.
typedef EventDetailScreenBuilder = Widget? Function(
  BuildContext context,
  String eventId,
);

/// Builds the retry-or-discard screen (#190) for the
/// [AppRoutes.stuckChanges] route. Supplied by [BgeApp]; returns null at
/// navigation time when no active server is resolvable or its container
/// lacks the queue or either repository a discard undoes through (tests
/// without a container; no active user session), in which case the route
/// falls back to [NotYetAvailableScreen].
///
/// Outside the auth [ShellRoute] for the collection list's reason: it needs
/// the active server's scoped container, not an `AuthBloc`. Pushed from the
/// home screen's notice.
typedef StuckChangesScreenBuilder = Widget? Function(BuildContext context);

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
  HouseholdInvitesScreenBuilder? householdInvitesBuilder,
  SendHouseholdInviteScreenBuilder? sendHouseholdInviteBuilder,
  EditHouseholdScreenBuilder? editHouseholdBuilder,
  InviteInboxScreenBuilder? inviteInboxBuilder,
  SentInvitesScreenBuilder? sentInvitesBuilder,
  CollectionListScreenBuilder? collectionListBuilder,
  GameBrowseScreenBuilder? gameBrowseBuilder,
  GameSearchScreenBuilder? gameSearchBuilder,
  GameDetailScreenBuilder? gameDetailBuilder,
  EventOverviewScreenBuilder? eventOverviewBuilder,
  EventGroupScreenBuilder? eventGroupBuilder,
  EventCreateScreenBuilder? eventCreateBuilder,
  EventDetailScreenBuilder? eventDetailBuilder,
  StuckChangesScreenBuilder? stuckChangesBuilder,
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
      // without a scope) the child renders bare and the route builders fall
      // back to their placeholders.
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
            // #455: the household's invites, its send form (#569) and its
            // edit form (#476), side by side and nested for the reason the
            // household children are (#308): a `go` to any of them builds
            // the household beneath it, so leaving is a plain pop. A
            // member's send is the exception, which leaves for the Sent
            // screen above the household.
            routes: [
              GoRoute(
                path: AppRoutes._householdInvitesSegment,
                builder: (context, state) {
                  final id =
                      state.pathParameters[AppRoutes.householdIdParam] ?? '';
                  return householdInvitesBuilder?.call(context, id) ??
                      const NotYetAvailableScreen();
                },
              ),
              // #569: the send form sits beside the invites rather than
              // under them. A member may send but can't read the invites,
              // so a `go` here builds the household beneath the form, not
              // a list that would answer them 403. The invites' own button
              // pushes it, which keeps the invites beneath.
              GoRoute(
                path: AppRoutes._householdInviteSendSegment,
                builder: (context, state) {
                  final id =
                      state.pathParameters[AppRoutes.householdIdParam] ?? '';
                  return sendHouseholdInviteBuilder?.call(context, id) ??
                      const NotYetAvailableScreen();
                },
              ),
              // #476: the household's edit form. A save leaves by a plain
              // pop.
              GoRoute(
                path: AppRoutes._householdEditSegment,
                builder: (context, state) {
                  final id =
                      state.pathParameters[AppRoutes.householdIdParam] ?? '';
                  return editHouseholdBuilder?.call(context, id) ??
                      const NotYetAvailableScreen();
                },
              ),
            ],
          ),
        ],
      ),
      // #455: the invites sent to the current user, from the home drawer.
      GoRoute(
        path: AppRoutes.invites,
        builder: (context, _) =>
            inviteInboxBuilder?.call(context) ?? const NotYetAvailableScreen(),
        routes: [
          // #487: the invites the current user sent, pushed from the inbox.
          GoRoute(
            path: 'sent',
            builder: (context, _) =>
                sentInvitesBuilder?.call(context) ??
                const NotYetAvailableScreen(),
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
      // #42: browse, search and one game. Outside the auth ShellRoute, like
      // the collection list, and pushed from the home drawer. Search and the
      // detail are children of browse, as the household children are of
      // their list (#308), so a `go` straight to either builds browse
      // beneath it.
      //
      // Search MUST stay declared above the detail: `search` is a legal
      // `:gameId`, and go_router takes the first declared match.
      GoRoute(
        path: AppRoutes.games,
        builder: (context, _) =>
            gameBrowseBuilder?.call(context) ?? const NotYetAvailableScreen(),
        routes: [
          GoRoute(
            path: AppRoutes._gameSearchSegment,
            builder: (context, _) =>
                gameSearchBuilder?.call(context) ??
                const NotYetAvailableScreen(),
          ),
          GoRoute(
            path: AppRoutes._gameDetailSegment,
            builder: (context, state) {
              final id = state.pathParameters[AppRoutes.gameIdParam] ?? '';
              return gameDetailBuilder?.call(context, id) ??
                  const NotYetAvailableScreen();
            },
          ),
        ],
      ),
      // #497: the events overview and a page per group. Outside the auth
      // ShellRoute, like the collection list, and pushed from the home
      // drawer. The group pages are children of the overview, as the
      // household children are of their list (#308), so a `go` straight to
      // one builds the overview beneath it.
      //
      // #499: the create form is a child of the overview too, beside the
      // group pages, so a `go` straight to it builds the overview beneath it,
      // which back from the event that replaces the form returns to.
      //
      // #498: one event is a child of the overview too, so a `go` straight to
      // it builds the overview beneath it. It MUST be declared after the
      // group pages and the create form: `upcoming` is a legal `:eventId`,
      // and so is `create`, and go_router takes the first declared match, as
      // with game search and the game detail.
      GoRoute(
        path: AppRoutes.events,
        builder: (context, _) =>
            eventOverviewBuilder?.call(context) ??
            const NotYetAvailableScreen(),
        routes: [
          for (final segment in AppRoutes.eventGroupSegments)
            GoRoute(
              path: segment,
              builder: (context, _) =>
                  eventGroupBuilder?.call(context, segment) ??
                  const NotYetAvailableScreen(),
            ),
          GoRoute(
            path: AppRoutes._eventCreateSegment,
            builder: (context, state) {
              final query = state.uri.queryParameters;
              final household = query[AppRoutes.eventCreateHouseholdParam];
              // An empty value names no household, as an absent one does.
              final householdId = household == null || household.isEmpty
                  ? null
                  : household;
              return eventCreateBuilder?.call(context, householdId) ??
                  const NotYetAvailableScreen();
            },
          ),
          GoRoute(
            path: AppRoutes._eventDetailSegment,
            builder: (context, state) {
              final id = state.pathParameters[AppRoutes.eventIdParam] ?? '';
              return eventDetailBuilder?.call(context, id) ??
                  const NotYetAvailableScreen();
            },
          ),
        ],
      ),
      // #190: the changes that couldn't sync. Outside the auth ShellRoute
      // (see [StuckChangesScreenBuilder]), pushed from the home notice, and
      // reachable only once [AppBootstrapReady] admits non-bootstrap
      // locations.
      GoRoute(
        path: AppRoutes.stuckChanges,
        builder: (context, _) =>
            stuckChangesBuilder?.call(context) ?? const NotYetAvailableScreen(),
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
/// [BgeApp]; when null the child renders bare (tests without a scope) and
/// the route builders fall back to placeholders.
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
