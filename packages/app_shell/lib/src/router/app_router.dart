import 'dart:async';

import 'package:app_shell/src/bootstrap/app_bootstrap_cubit.dart';
import 'package:app_shell/src/bootstrap/app_bootstrap_state.dart';
import 'package:app_shell/src/navigation/shell_modal_guard.dart';
import 'package:app_shell/src/screens/bootstrap_error_screen.dart';
import 'package:app_shell/src/screens/not_yet_available_screen.dart';
import 'package:app_shell/src/screens/route_not_found_screen.dart';
import 'package:app_shell/src/screens/shell_placeholder_screen.dart';
import 'package:app_shell/src/screens/splash_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart' show BgePopupCoverObserver, BgeTopLevelRoute;

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

  /// One entry of the [collection] list (#46), beneath it, so a location
  /// straight to an entry still builds the list under it. Build a concrete
  /// location with [collectionEntryOf].
  static const collectionEntry = '$collection/:$collectionEntryIdParam';

  /// The id segment of [collectionEntry].
  static const collectionEntryIdParam = 'entryId';

  /// The location of one collection entry's detail screen.
  static String collectionEntryOf(String entryId) =>
      '$collection/${Uri.encodeComponent(entryId)}';

  /// The server's games, to browse (#42). Plural, unlike [household] and
  /// [collection]: it lists the catalog, not one thing the user has. Not the
  /// reserved `/server/:serverId/game/:gameId` deep link, which names a
  /// server; that stays reserved until #10 can tell whose server it names.
  static const games = '/games';

  /// [games], starting in [sort]: what opens the list newest first (#615).
  ///
  /// The query sets the order of the first read only. The screen's own menu
  /// changes it from there without rewriting the location, and nothing keeps
  /// the choice, so the drawer's plain [games] always opens in title order.
  /// That is why title is the plain location rather than `?sort=title`.
  static String gamesSorted(GameSort sort) =>
      sort == GameSort.title ? games : '$games?$_gamesSortParam=${sort.wire}';

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

  /// The query parameter naming the order [games] starts in.
  static const _gamesSortParam = 'sort';

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
  /// **overlap**: `upcoming` and `archived` are legal event ids, so the group
  /// pages are declared first and the detail after them, as game search is
  /// before the game detail.
  static const eventGroupSegments = <String>[
    'upcoming',
    'planning',
    'past',
    'archived',
  ];

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

  /// Who answered one event's availability poll (#507), beneath its detail.
  /// Build a concrete location with [eventAvailabilityOf].
  static const eventAvailability = '$eventDetail/$_eventAvailabilitySegment';

  static const _eventAvailabilitySegment = 'availability';

  /// The location of the page of who answered one event's poll.
  static String eventAvailabilityOf(String eventId) =>
      '${eventDetailOf(eventId)}/$_eventAvailabilitySegment';

  /// The Add people page of one event (#510), beneath its detail. Build a
  /// concrete location with [eventAddAttendeeOf].
  ///
  /// The page is opened only from the detail, which hands it what to offer
  /// as the push's `extra`. A deep link carries none, and is sent to the
  /// detail: see [EventAddAttendeeScreenBuilder].
  static const eventAddAttendee = '$eventDetail/$_eventAddAttendeeSegment';

  static const _eventAddAttendeeSegment = 'attendees/add';

  /// The location of one event's Add people page.
  static String eventAddAttendeeOf(String eventId) =>
      '${eventDetailOf(eventId)}/$_eventAddAttendeeSegment';

  /// The Offer games page of one event (#516), beneath its detail. Build a
  /// concrete location with [eventOfferGamesOf].
  ///
  /// The page is opened only from the detail's Games tab, which hands it
  /// what to leave out as the push's `extra`. A deep link carries none, and
  /// is sent to the detail: see [EventOfferGamesScreenBuilder].
  static const eventOfferGames = '$eventDetail/$_eventOfferGamesSegment';

  static const _eventOfferGamesSegment = 'games/offer';

  /// The location of one event's Offer games page.
  static String eventOfferGamesOf(String eventId) =>
      '${eventDetailOf(eventId)}/$_eventOfferGamesSegment';

  /// The changes that couldn't sync, each with a retry and a discard
  /// (#190). Always the active session's own, like [collection].
  static const stuckChanges = '/stuck-changes';

  /// The admin dashboard (#684): the server administration sections the
  /// caller's access shows. Each section's screens are its children, so a
  /// deep link to one builds the dashboard beneath it.
  static const admin = '/admin';

  /// The DataGateway admin list (#41), a section beneath [admin] (#684). The
  /// path is the one it had before the dashboard.
  static const adminDataGateways = '$admin/$_adminDataGatewaysSegment';

  // The sections' paths relative to [admin], which is how the route table
  // declares them, as with the household children (#308).
  static const _adminDataGatewaysSegment = 'data-gateways';
  static const _adminHouseholdsSegment = 'households';
  static const _adminSettingsSegment = 'settings';

  /// The add form, beneath the list.
  static const dataGatewayAdd = '$adminDataGateways/$_dataGatewayAddSegment';

  /// The edit form for one DataGateway, beneath the list. Build a concrete
  /// location with [dataGatewayEditOf].
  static const dataGatewayEdit = '$adminDataGateways/$_dataGatewayEditSegment';

  /// One DataGateway's own page (#457), beneath the list. Build a concrete
  /// location with [dataGatewayDetailOf].
  ///
  /// This pattern and [dataGatewayAdd] **overlap**: `new` is a legal id
  /// segment, so the add form is declared first, or it would open as the
  /// detail of a DataGateway with the id "new". [dataGatewayEdit] does not
  /// overlap this: it has two segments below the list, and this has one.
  static const dataGatewayDetail =
      '$adminDataGateways/$_dataGatewayDetailSegment';

  /// The id segment of [dataGatewayEdit] and [dataGatewayDetail].
  static const dataGatewayIdParam = 'dataGatewayId';

  static const _dataGatewayAddSegment = 'new';
  static const _dataGatewayDetailSegment = ':$dataGatewayIdParam';
  static const _dataGatewayEditSegment = ':$dataGatewayIdParam/edit';

  /// The location of one DataGateway's edit form.
  static String dataGatewayEditOf(String id) =>
      '$adminDataGateways/${Uri.encodeComponent(id)}/edit';

  /// The location of one DataGateway's own page.
  static String dataGatewayDetailOf(String id) =>
      '$adminDataGateways/${Uri.encodeComponent(id)}';

  /// Every household on the server, deleted ones too (#685), a section
  /// beneath [admin] (#684). Not [household], which lists the caller's own.
  static const adminHouseholds = '$admin/$_adminHouseholdsSegment';

  /// The server's own settings (#807): its mail, and how people sign in. A
  /// section beneath [admin] (#684). Not the user's own settings screen.
  static const adminSettings = '$admin/$_adminSettingsSegment';

  /// The id segment of one household's staff detail, beneath
  /// [adminHouseholds]. Build a concrete location with
  /// [adminHouseholdDetailOf].
  static const adminHouseholdIdParam = 'adminHouseholdId';

  static const _adminHouseholdDetailSegment = ':$adminHouseholdIdParam';

  /// The location of one household's staff detail (#685).
  static String adminHouseholdDetailOf(String id) =>
      '$adminHouseholds/${Uri.encodeComponent(id)}';

  static const error = '/error';

  /// The bootstrap-owned locations a ready app is bounced away from.
  /// `settings` is deliberately absent: it is a normal post-ready
  /// destination, not a bootstrap leg, so a ready app is not bounced off
  /// it (#120).
  static const Set<String> bootstrapLocations = {
    splash,
    error,
    serverAdd,
    auth,
  };
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
/// [AppRoutes.serverAdd] route. Always supplied by `BgeApp`; returns null
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
/// Always supplied by `BgeApp`; returns null at navigation time when no
/// active server is resolvable, in which case the route falls back to the
/// placeholder.
///
/// That fallback is a dead end, not a transient state: the redirect pins
/// [AppBootstrapNeedsAuth] to this route. Native bootstrap fails as a
/// retryable error rather than reach it (#217), and the builder logs an
/// error naming the cause if it ever is reached.
typedef AuthScreenBuilder = Widget? Function(BuildContext context);

/// Builds the user-initiated feedback flow (#107) for the
/// [AppRoutes.feedback] route. Supplied by `BgeApp`; returns null at
/// navigation time when the root container carries no `FeedbackService`
/// (tests without a container; a platform composition that skipped
/// feedback wiring), in which case the route falls back to
/// [NotYetAvailableScreen].
///
/// The route sits inside the navigation shell (#414), itself inside the auth
/// [ShellRoute], so `AuthBloc` and the unverified-session banner reach it
/// (#145). The flow doesn't read the bloc: submission goes through the
/// device-global service, which owns the send-or-queue decision.
/// Reachability is post-auth by design (multi-server: a report must be
/// attributable to a target server): the redirect table only admits
/// non-bootstrap locations once [AppBootstrapReady].
typedef FeedbackScreenBuilder = Widget? Function(BuildContext context);

/// Builds the settings surface (#120) for the [AppRoutes.settings] route.
/// Supplied by `BgeApp`; returns null at navigation time when the
/// app-level settings controllers are not yet available (before the first
/// storage-ready bootstrap state, or a boot where hydrated storage was
/// unavailable), in which case the route falls back to
/// [NotYetAvailableScreen].
///
/// Like feedback, the route sits inside the navigation shell (#414) and so
/// inside the auth [ShellRoute] (#145), and is reachable only once
/// [AppBootstrapReady] admits non-bootstrap locations. `settings` is not
/// in [AppRoutes.bootstrapLocations], so a ready app is not bounced away
/// from it.
typedef SettingsScreenBuilder = Widget? Function(BuildContext context);

/// Builds the create-household flow (#129) for the
/// [AppRoutes.householdCreate] route. Supplied by `BgeApp`; returns null at
/// navigation time when no active server is resolvable or its container
/// carries no `HouseholdRepository` / `SyncOperationSender` (tests without a
/// container; no active user session), in which case the route falls back
/// to [NotYetAvailableScreen]. Both platforms wire both halves in a real
/// session.
///
/// The route sits inside the navigation shell (#414) and so inside the auth
/// [ShellRoute] (#145). The screen reads the active server's scoped
/// container, not the `AuthBloc`. Reachability is post-auth — the redirect
/// table only admits non-bootstrap locations once [AppBootstrapReady] — and
/// it is pushed from the household list's FAB (#269) rather than
/// deep-linked.
typedef CreateHouseholdScreenBuilder = Widget? Function(BuildContext context);

/// Builds the household list (#269) for the [AppRoutes.household] route.
/// Supplied by `BgeApp`; returns null at navigation time when no active
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
/// Sits inside the navigation shell (#414), like the create route; it reads
/// the active server's scoped container, not the `AuthBloc`.
typedef HouseholdListScreenBuilder = Widget? Function(BuildContext context);

/// Builds one household's detail screen (#270) for the
/// [AppRoutes.householdDetail] route, given the `:householdId` the path
/// carried. Supplied by `BgeApp`; returns null on the same conditions as
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
/// Supplied by `BgeApp`; returns null when no active server is resolvable
/// or its container lacks the `HouseholdInviteRemoteDataSource`, in which
/// case the route falls back to [NotYetAvailableScreen].
typedef InviteInboxScreenBuilder = Widget? Function(BuildContext context);

/// Builds the invites the current user sent (#487) for the
/// [AppRoutes.invitesSent] route. Supplied by `BgeApp`; same null contract
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
/// Supplied by `BgeApp`; returns null at navigation time when no active
/// server is resolvable or its container carries no
/// `GameCollectionRepository` (tests without a container; no active user
/// session), in which case the route falls back to [NotYetAvailableScreen].
///
/// Guarded on the repository alone, like the household list: the list reads
/// the local cache, and a missing hydrate costs it only the retry.
///
/// Sits inside the navigation shell (#414), like the household list; it
/// reads the active server's scoped container, not the `AuthBloc`.
typedef CollectionListScreenBuilder = Widget? Function(BuildContext context);

/// Builds one collection entry's detail (#46) for the
/// [AppRoutes.collectionEntry] route. Same null contract as
/// [CollectionListScreenBuilder], and null as well when the active container
/// carries no `SyncOperationSender` for the edit and the removal to send
/// through; the route then falls back to [NotYetAvailableScreen].
typedef CollectionEntryScreenBuilder = Widget? Function(
  BuildContext context,
  String entryId,
);

/// Builds the game browse screen (#42) for the [AppRoutes.games] route.
/// Supplied by `BgeApp`; returns null at navigation time when no active
/// server is resolvable or its container carries no `GamesRemoteDataSource`,
/// in which case the route falls back to [NotYetAvailableScreen].
///
/// Guarded on the remote alone: the games cache is optional, and without it
/// the screen still reads the server, with nothing to show offline.
///
/// [sort] is the order the list starts in: the location's `sort` query
/// ([AppRoutes.gamesSorted]), or title where there is none or it names no
/// sort.
typedef GameBrowseScreenBuilder = Widget? Function(
  BuildContext context,
  GameSort sort,
);

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
/// Supplied by `BgeApp`; returns null at navigation time when no active
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
/// none. Supplied by `BgeApp`; returns null at navigation time when no active
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

/// Builds the page of who answered one event's availability poll (#507) for
/// the [AppRoutes.eventAvailability] route, given the `:eventId` the path
/// carried. Same null contract as [EventOverviewScreenBuilder].
///
/// The id reaches the builder unvalidated. The page answers one that names
/// no event, or one whose answers the viewer can't see, by saying it can't
/// show them.
typedef EventAvailabilityScreenBuilder = Widget? Function(
  BuildContext context,
  String eventId,
);

/// Builds one event's Add people page (#510) for the
/// [AppRoutes.eventAddAttendee] route, given the `:eventId` the path carried
/// and the `extra` the detail pushed it with: what the page offers, worked
/// out from the open detail. Same null contract as
/// [EventOverviewScreenBuilder], and null too for [args] the builder doesn't
/// recognise.
///
/// [args] is `Object`, not the events feature's own type, so this file stays
/// free of feature packages, as every other builder here is typed by ids.
///
/// A location that carries no `extra`, as a deep link or a `go` doesn't, is
/// redirected to the event's detail, where the page is opened from. One
/// more location carries none: the page's own browser history entry,
/// restored by Back or Forward on the web once the page has closed. go_router
/// keeps a push's `extra` there only as JSON, which the page's isn't, and
/// runs no route redirect on a restored push. So there the route builds
/// nothing and leaves for the detail beneath it at once, in that entry's
/// place: not a page whose answer nobody awaits any more, nor a placeholder
/// that says the page doesn't exist. Only `extra` the builder doesn't
/// recognise, which nothing pushes, falls back to [NotYetAvailableScreen].
typedef EventAddAttendeeScreenBuilder = Widget? Function(
  BuildContext context,
  String eventId,
  Object args,
);

/// Builds one event's Offer games page (#516) for the
/// [AppRoutes.eventOfferGames] route, given the `:eventId` the path carried
/// and the `extra` the detail's Games tab pushed it with: the collection
/// entries the viewer has offered already, worked out from the open detail.
/// Same null contract as [EventOverviewScreenBuilder], and null too for
/// [args] the builder doesn't recognise.
///
/// Everything else is [EventAddAttendeeScreenBuilder]'s: [args] is `Object`
/// so this file stays free of feature packages; a location that carries no
/// `extra`, a deep link or a `go`, is redirected to the event's detail; the
/// page's own browser history entry, restored once the page has closed,
/// builds nothing and leaves for the detail beneath it at once, in that
/// entry's place; and only `extra` the builder doesn't recognise, which
/// nothing pushes, falls back to [NotYetAvailableScreen].
typedef EventOfferGamesScreenBuilder = Widget? Function(
  BuildContext context,
  String eventId,
  Object args,
);

/// Builds the retry-or-discard screen (#190) for the
/// [AppRoutes.stuckChanges] route. Supplied by `BgeApp`; returns null at
/// navigation time when no active server is resolvable or its container
/// lacks the queue or either repository a discard undoes through (tests
/// without a container; no active user session), in which case the route
/// falls back to [NotYetAvailableScreen].
///
/// Inside the navigation shell (#414), like the collection list; it reads
/// the active server's scoped container, not the `AuthBloc`. Pushed from the
/// home screen's notice.
typedef StuckChangesScreenBuilder = Widget? Function(BuildContext context);

/// Builds the DataGateway admin list (#41) for the
/// [AppRoutes.adminDataGateways] route. Supplied by `BgeApp`; returns null
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

/// Builds one DataGateway's own page (#457) for [dataGatewayId]. Same null
/// contract as [DataGatewayListScreenBuilder].
typedef DataGatewayDetailScreenBuilder = Widget? Function(
  BuildContext context,
  String dataGatewayId,
);

/// Builds the admin dashboard (#684) for the [AppRoutes.admin] route.
/// Supplied by `BgeApp`; returns null when no active server is resolvable,
/// in which case the route falls back to [NotYetAvailableScreen].
///
/// Not gated on the user's access, as [DataGatewayListScreenBuilder] isn't:
/// the dashboard says why it shows no section.
typedef AdminDashboardScreenBuilder = Widget? Function(BuildContext context);

/// Builds the staff households list (#685) for the [AppRoutes.adminHouseholds]
/// route. Supplied by `BgeApp`; returns null when no active server is
/// resolvable or its container carries no `AdminHouseholdRemoteDataSource`,
/// in which case the route falls back to [NotYetAvailableScreen].
///
/// Not gated on the user's access: the list says when the server refuses it.
typedef AdminHouseholdListScreenBuilder = Widget? Function(
  BuildContext context,
);

/// Builds the server settings screen (#807) for the [AppRoutes.adminSettings]
/// route. Supplied by `BgeApp`; returns null when no active server is
/// resolvable or its container carries no `SystemSettingsRemoteDataSource` or
/// `NotificationRemoteDataSource`, in which case the route falls back to
/// [NotYetAvailableScreen].
///
/// Not gated on the user's access: the screen says when the server refuses it.
typedef ServerSettingsScreenBuilder = Widget? Function(BuildContext context);

/// Builds one household's staff detail (#685) for [householdId]. Same null
/// contract as [AdminHouseholdListScreenBuilder].
typedef AdminHouseholdDetailScreenBuilder = Widget? Function(
  BuildContext context,
  String householdId,
);

/// Makes the location the router reports for the address bar follow pushed
/// screens, not only the declarative stack beneath them (#321). The web
/// composition calls it before the router is built; native doesn't.
///
/// Without it, every `push` leaves the address bar on the location beneath,
/// `/home` for most of the app, and browser Back leaves the app.
///
/// go_router warns against the setting because the top route's location
/// isn't always deep-linkable. Here it is, and the route table keeps it so:
///
/// - Every location the app pushes is a declared path, built by an
///   `AppRoutes.*Of` helper, that parses on its own.
/// - A child screen nests under the screen it's reached from (#308), so
///   entering it directly builds its parent beneath it.
///
/// go_router reports each location change, pops and replacements included,
/// as a new browser history entry that carries its whole stack, and restores
/// that stack when Back or Forward returns to the entry. Restoring a screen
/// on reload, or from a bookmark, needs the location kept through bootstrap
/// and sign-in, which is #83's.
void reflectPushedRoutesInUrl() =>
    GoRouter.optionURLReflectsImperativeAPIs = true;

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
  NavigationShellBuilder? navigationShellBuilder,
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
  CollectionEntryScreenBuilder? collectionEntryBuilder,
  GameBrowseScreenBuilder? gameBrowseBuilder,
  GameSearchScreenBuilder? gameSearchBuilder,
  GameDetailScreenBuilder? gameDetailBuilder,
  EventOverviewScreenBuilder? eventOverviewBuilder,
  EventGroupScreenBuilder? eventGroupBuilder,
  EventCreateScreenBuilder? eventCreateBuilder,
  EventDetailScreenBuilder? eventDetailBuilder,
  EventAvailabilityScreenBuilder? eventAvailabilityBuilder,
  EventAddAttendeeScreenBuilder? eventAddAttendeeBuilder,
  EventOfferGamesScreenBuilder? eventOfferGamesBuilder,
  StuckChangesScreenBuilder? stuckChangesBuilder,
  DataGatewayListScreenBuilder? dataGatewayListBuilder,
  DataGatewayFormScreenBuilder? dataGatewayFormBuilder,
  DataGatewayDetailScreenBuilder? dataGatewayDetailBuilder,
  AdminDashboardScreenBuilder? adminDashboardBuilder,
  AdminHouseholdListScreenBuilder? adminHouseholdListBuilder,
  AdminHouseholdDetailScreenBuilder? adminHouseholdDetailBuilder,
  ServerSettingsScreenBuilder? serverSettingsBuilder,
}) {
  // #414: a modal on the root navigator leaves with the navigation shell
  // page it was opened over. One per router.
  final modalGuard = ShellModalGuard();
  return GoRouter(
    initialLocation: AppRoutes.splash,
    observers: [modalGuard.rootObserver],
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
    // An unknown location, reachable only once ready: before that the
    // redirect above pins every location to a bootstrap screen.
    errorPageBuilder: (context, state) =>
        _materialPage(state, const RouteNotFoundScreen()),
    // Every route builds its page explicitly; see [_materialPage] for why,
    // and for which routes keep no transition.
    //
    // On web, pushed locations show in the address bar, so every location
    // the app pushes must be a declared path that parses on its own, with a
    // child nested under the screen it's reached from (#321; see
    // [reflectPushedRoutesInUrl]).
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        pageBuilder: (_, state) =>
            _noTransitionPage(state, const SplashScreen()),
      ),
      GoRoute(
        path: AppRoutes.serverAdd,
        // Real server-add UI (#36) when the shell supplied a builder;
        // the placeholder otherwise (tests, web).
        pageBuilder: (context, state) => _noTransitionPage(
          state,
          serverAddBuilder?.call(context) ??
              const ShellPlaceholderScreen(
                kind: ShellPlaceholderKind.serverAdd,
              ),
        ),
      ),
      // #37: the auth route and the navigation shell (#414) share ONE AuthBloc,
      // provided by [authScopeBuilder] inside the router subtree — go_router
      // builds route widgets under its own Navigator, which does not inherit
      // providers placed above the router's widget, so the provider must live
      // here (a ShellRoute), not app-level. The shell's scope builder creates
      // the keyed provider + drives the bootstrap gate from the bloc's terminal
      // auth states; a single instance survives the auth → home transition.
      // When no scope builder is supplied (tests without a scope) the child
      // renders bare and the route builders fall back to their placeholders.
      //
      // #414: every signed-in route sits in the navigation shell nested here,
      // so the auth scope (and #145's unverified-session banner) reaches all of
      // them. `/auth` stays beside it, outside the shell.
      ShellRoute(
        builder: (context, state, child) =>
            authScopeBuilder?.call(context, child) ?? child,
        routes: [
          GoRoute(
            path: AppRoutes.auth,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              authBuilder?.call(context) ??
                  const ShellPlaceholderScreen(kind: ShellPlaceholderKind.auth),
            ),
          ),
          // #414: the navigation shell. The location it hands the builder
          // is this route's own `state.uri.path`: it follows a push, a go,
          // a pop and browser Back. `state.matchedLocation` goes stale
          // (it stays the declarative base after a push) and
          // `routeInformationProvider.value` holds the pre-pop URL during
          // build, so neither will do. Its own page is left as go_router
          // builds it, like the auth [ShellRoute]'s (see [_materialPage]).
          //
          // #707: showBgePopup keeps pop-ups on the root navigator so their
          // barrier covers the shell's bar or rail. The observer tells them
          // of a page pushed inside the shell, so a page opened from a
          // pop-up still removes it once it has arrived (#414). One per
          // navigator, made here so each router has its own.
          //
          // #414: the guard hears this navigator's pages leave, and the
          // shell itself leave, to take a root modal down with its page.
          //
          // #611: each route directly under the shell is the top of a
          // section, a destination or a screen the menu opens, and wraps
          // its page in a [BgeTopLevelRoute]. Where the browser owns Back,
          // such a page shows the menu however it was reached, and a page
          // under one shows no in-app arrow. The routes nested beneath them
          // are not wrapped.
          ShellRoute(
            observers: [BgePopupCoverObserver(), modalGuard.shellObserver],
            builder: (context, state, child) => modalGuard.wrapShell(
              navigationShellBuilder?.call(context, state.uri.path, child) ??
                  child,
            ),
            routes: [
              GoRoute(
                path: AppRoutes.home,
                // Home is only reached once [AppBootstrapReady] (post-auth,
                // active server present), so homeBuilder returns null only in a
                // transient/defensive pre-active state. Falls back to
                // [NotYetAvailableScreen]: static (so widget tests settle —
                // a spinner would hang pumpAndSettle) and consistent with the
                // other optional-builder routes (feedback / settings /
                // householdCreate). The home placeholder is retired (#129).
                pageBuilder: (context, state) => _noTransitionPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        homeBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
              ),
              // #107: user-initiated feedback. Inside the navigation shell
              // (#414) and the auth scope (see [FeedbackScreenBuilder]);
              // reachable only when [AppBootstrapReady] admits non-bootstrap
              // locations.
              GoRoute(
                path: AppRoutes.feedback,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        feedbackBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
              ),
              // #120: user settings. Inside the navigation shell (#414) and the
              // auth scope (see [SettingsScreenBuilder]); reachable only when
              // [AppBootstrapReady] admits non-bootstrap locations, and not
              // bounced (settings is not a bootstrap location).
              GoRoute(
                path: AppRoutes.settings,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        settingsBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
              ),
              // ── The household routes: why they nest, and their order ──
              //
              // `/household/create` (#129) and `/household/:householdId` (#270)
              // are children of `/household` (#269), not its siblings (#308). A
              // `go` to either therefore builds the list beneath it, so there
              // is always something to go back to — which is what lets the
              // detail screen's way back be a plain pop. A `push` still adds
              // only the leaf page, so the menu's Households entry pushes the
              // list over whatever page is current.
              //
              // Order among the children is the part that cannot change.
              // `create` is a perfectly legal `:householdId`, so
              // `/household/create` matches BOTH children. go_router takes the
              // first declared match, so create must come first or the create
              // flow silently becomes a detail screen for a household nobody
              // can have.
              //
              // The detail screen also answers a literal `create` id with its
              // not-found state (#270). That is the belt to this ordering's
              // braces — cheap, and it keeps the failure legible if these are
              // ever reordered.
              GoRoute(
                path: AppRoutes.household,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        householdListBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
                routes: [
                  // #129: create-household flow. Inside the navigation shell
                  // (#414) and the auth scope; it reads the active server's
                  // container (see [CreateHouseholdScreenBuilder]). Reachable
                  // only once [AppBootstrapReady] admits non-bootstrap
                  // locations; pushed from the list screen's FAB (#269).
                  //
                  // MUST stay declared above the detail route — see the block
                  // above.
                  GoRoute(
                    path: AppRoutes._householdCreateSegment,
                    pageBuilder: (context, state) => _materialPage(
                      state,
                      createHouseholdBuilder?.call(context) ??
                          const NotYetAvailableScreen(),
                    ),
                  ),
                  // #270: one household, read-only. Pushed from a list row, and
                  // where the reserved invite deep link eventually lands —
                  // which is why the id-addressed route exists now rather than
                  // later.
                  GoRoute(
                    path: AppRoutes._householdDetailSegment,
                    pageBuilder: (context, state) {
                      final id =
                          state.pathParameters[AppRoutes.householdIdParam] ??
                          '';
                      return _materialPage(
                        state,
                        householdDetailBuilder?.call(context, id) ??
                            const NotYetAvailableScreen(),
                      );
                    },
                    // #455: the household's invites, its send form (#569) and
                    // its edit form (#476), side by side and nested for the
                    // reason the household children are (#308): a `go` to any
                    // of them builds the household beneath it, so leaving is a
                    // plain pop. A member's send is the exception, which leaves
                    // for the Sent screen above the household.
                    routes: [
                      GoRoute(
                        path: AppRoutes._householdInvitesSegment,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes
                                  .householdIdParam] ??
                              '';
                          return _materialPage(
                            state,
                            householdInvitesBuilder?.call(context, id) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                      // #569: the send form sits beside the invites rather than
                      // under them. A member may send but can't read the
                      // invites, so a `go` here builds the household beneath
                      // the form, not a list that would answer them 403. The
                      // invites' own button pushes it, which keeps the invites
                      // beneath.
                      GoRoute(
                        path: AppRoutes._householdInviteSendSegment,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes
                                  .householdIdParam] ??
                              '';
                          return _materialPage(
                            state,
                            sendHouseholdInviteBuilder?.call(context, id) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                      // #476: the household's edit form. A save leaves by a
                      // plain pop.
                      GoRoute(
                        path: AppRoutes._householdEditSegment,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes
                                  .householdIdParam] ??
                              '';
                          return _materialPage(
                            state,
                            editHouseholdBuilder?.call(context, id) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
              // #455: the invites sent to the current user, pushed from the
              // navigation menu.
              GoRoute(
                path: AppRoutes.invites,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        inviteInboxBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
                routes: [
                  // #487: the invites the current user sent, pushed from the
                  // inbox.
                  GoRoute(
                    path: 'sent',
                    pageBuilder: (context, state) => _materialPage(
                      state,
                      sentInvitesBuilder?.call(context) ??
                          const NotYetAvailableScreen(),
                    ),
                  ),
                ],
              ),
              // #44: the collection list. Inside the navigation shell (#414)
              // and the auth scope (see [CollectionListScreenBuilder]), a
              // top-level destination, and reachable only once
              // [AppBootstrapReady] admits non-bootstrap locations. #46: one
              // entry is a child, so a location straight to it builds the list
              // beneath, and the entry's pop after a removal lands on the list.
              GoRoute(
                path: AppRoutes.collection,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        collectionListBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
                routes: [
                  GoRoute(
                    path: ':${AppRoutes.collectionEntryIdParam}',
                    pageBuilder: (context, state) {
                      final id =
                          state.pathParameters[AppRoutes
                              .collectionEntryIdParam] ??
                          '';
                      return _materialPage(
                        state,
                        collectionEntryBuilder?.call(context, id) ??
                            const NotYetAvailableScreen(),
                      );
                    },
                  ),
                ],
              ),
              // #42: browse, search and one game. Inside the navigation shell
              // (#414), like the collection list, and a top-level destination.
              // Search and the detail are children of browse, as the household
              // children are of their list (#308), so a `go` straight to either
              // builds browse beneath it.
              //
              // Search MUST stay declared above the detail: `search` is a legal
              // `:gameId`, and go_router takes the first declared match.
              GoRoute(
                path: AppRoutes.games,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        gameBrowseBuilder?.call(
                          context,
                          GameSort.fromWire(
                                state.uri.queryParameters[AppRoutes
                                    ._gamesSortParam],
                              ) ??
                              GameSort.title,
                        ) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
                routes: [
                  GoRoute(
                    path: AppRoutes._gameSearchSegment,
                    pageBuilder: (context, state) => _materialPage(
                      state,
                      gameSearchBuilder?.call(context) ??
                          const NotYetAvailableScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes._gameDetailSegment,
                    pageBuilder: (context, state) {
                      final id =
                          state.pathParameters[AppRoutes.gameIdParam] ?? '';
                      return _materialPage(
                        state,
                        gameDetailBuilder?.call(context, id) ??
                            const NotYetAvailableScreen(),
                      );
                    },
                  ),
                ],
              ),
              // #497: the events overview and a page per group. Inside the
              // navigation shell (#414), like the collection list, and a
              // top-level destination. The group pages are children of the
              // overview, as the household children are of their list (#308),
              // so a `go` straight to one builds the overview beneath it.
              //
              // #499: the create form is a child of the overview too, beside
              // the group pages, so a `go` straight to it builds the overview
              // beneath it, which back from the event that replaces the form
              // returns to.
              //
              // #498: one event is a child of the overview too, so a `go`
              // straight to it builds the overview beneath it. It MUST be
              // declared after the group pages and the create form: `upcoming`
              // is a legal `:eventId`, and so is `create`, and go_router takes
              // the first declared match, as with game search and the game
              // detail.
              GoRoute(
                path: AppRoutes.events,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        eventOverviewBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
                routes: [
                  for (final segment in AppRoutes.eventGroupSegments)
                    GoRoute(
                      path: segment,
                      pageBuilder: (context, state) => _materialPage(
                        state,
                        eventGroupBuilder?.call(context, segment) ??
                            const NotYetAvailableScreen(),
                      ),
                    ),
                  GoRoute(
                    path: AppRoutes._eventCreateSegment,
                    pageBuilder: (context, state) {
                      final query = state.uri.queryParameters;
                      final household =
                          query[AppRoutes.eventCreateHouseholdParam];
                      // An empty value names no household, as an absent one
                      // does.
                      final householdId = household == null || household.isEmpty
                          ? null
                          : household;
                      return _materialPage(
                        state,
                        eventCreateBuilder?.call(context, householdId) ??
                            const NotYetAvailableScreen(),
                      );
                    },
                  ),
                  GoRoute(
                    path: AppRoutes._eventDetailSegment,
                    pageBuilder: (context, state) {
                      final id =
                          state.pathParameters[AppRoutes.eventIdParam] ?? '';
                      return _materialPage(
                        state,
                        eventDetailBuilder?.call(context, id) ??
                            const NotYetAvailableScreen(),
                      );
                    },
                    // #507: who answered the event's poll, nested for the
                    // reason the household children are (#308): a `go` straight
                    // to it builds the event beneath it, so back is a plain pop
                    // to there.
                    //
                    // #510: the Add people page, nested the same way. It is
                    // built only from what the detail pushed it with, so a deep
                    // link lands on the detail instead (see
                    // [EventAddAttendeeScreenBuilder]).
                    //
                    // #516: the Offer games page, nested and built as Add
                    // people's is (see [EventOfferGamesScreenBuilder]).
                    routes: [
                      GoRoute(
                        path: AppRoutes._eventAvailabilitySegment,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes.eventIdParam] ??
                              '';
                          return _materialPage(
                            state,
                            eventAvailabilityBuilder?.call(context, id) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                      GoRoute(
                        path: AppRoutes._eventAddAttendeeSegment,
                        redirect: (context, state) => state.extra == null
                            ? AppRoutes.eventDetailOf(
                                state.pathParameters[AppRoutes.eventIdParam] ??
                                    '',
                              )
                            : null,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes.eventIdParam] ??
                              '';
                          final args = state.extra;
                          // The page's own history entry, restored once the
                          // page has closed, which the redirect never sees.
                          if (args == null) {
                            return _passThroughPage(
                              state,
                              _LeaveForEvent(eventId: id),
                            );
                          }
                          return _materialPage(
                            state,
                            eventAddAttendeeBuilder?.call(context, id, args) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                      GoRoute(
                        path: AppRoutes._eventOfferGamesSegment,
                        redirect: (context, state) => state.extra == null
                            ? AppRoutes.eventDetailOf(
                                state.pathParameters[AppRoutes.eventIdParam] ??
                                    '',
                              )
                            : null,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes.eventIdParam] ??
                              '';
                          final args = state.extra;
                          // The page's own history entry, restored once the
                          // page has closed, which the redirect never sees.
                          if (args == null) {
                            return _passThroughPage(
                              state,
                              _LeaveForEvent(eventId: id),
                            );
                          }
                          return _materialPage(
                            state,
                            eventOfferGamesBuilder?.call(context, id, args) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
              // #190: the changes that couldn't sync. Inside the navigation
              // shell (#414; see [StuckChangesScreenBuilder]), pushed from the
              // home notice, and reachable only once [AppBootstrapReady] admits
              // non-bootstrap locations.
              GoRoute(
                path: AppRoutes.stuckChanges,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        stuckChangesBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
              ),
              // #684: the admin dashboard, with each section's screens beneath
              // it, so a deep link to a section builds the dashboard beneath it
              // and leaving the section is a plain pop back to it. The
              // sections' paths didn't change when they moved beneath it.
              GoRoute(
                path: AppRoutes.admin,
                pageBuilder: (context, state) => _materialPage(
                  state,
                  BgeTopLevelRoute(
                    child:
                        adminDashboardBuilder?.call(context) ??
                        const NotYetAvailableScreen(),
                  ),
                ),
                routes: [
                  // #41: the DataGateway admin screens. The forms and a
                  // DataGateway's own page (#457) are children of the list, as
                  // the household children are of theirs (#308), so a deep link
                  // to one builds the list beneath it and leaving it is a plain
                  // pop. The add form stays ahead of the detail: see
                  // [AppRoutes.dataGatewayDetail].
                  GoRoute(
                    path: AppRoutes._adminDataGatewaysSegment,
                    pageBuilder: (context, state) => _materialPage(
                      state,
                      dataGatewayListBuilder?.call(context) ??
                          const NotYetAvailableScreen(),
                    ),
                    routes: [
                      GoRoute(
                        path: AppRoutes._dataGatewayAddSegment,
                        pageBuilder: (context, state) => _materialPage(
                          state,
                          dataGatewayFormBuilder?.call(context, null) ??
                              const NotYetAvailableScreen(),
                        ),
                      ),
                      GoRoute(
                        path: AppRoutes._dataGatewayDetailSegment,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes
                                  .dataGatewayIdParam] ??
                              '';
                          return _materialPage(
                            state,
                            dataGatewayDetailBuilder?.call(context, id) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                      GoRoute(
                        path: AppRoutes._dataGatewayEditSegment,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes
                                  .dataGatewayIdParam] ??
                              '';
                          return _materialPage(
                            state,
                            dataGatewayFormBuilder?.call(context, id) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                    ],
                  ),
                  // #685: every household on the server, with a live one's
                  // staff detail beneath the list, for the reason the
                  // DataGateway page is beneath its list.
                  GoRoute(
                    path: AppRoutes._adminHouseholdsSegment,
                    pageBuilder: (context, state) => _materialPage(
                      state,
                      adminHouseholdListBuilder?.call(context) ??
                          const NotYetAvailableScreen(),
                    ),
                    routes: [
                      GoRoute(
                        path: AppRoutes._adminHouseholdDetailSegment,
                        pageBuilder: (context, state) {
                          final id =
                              state.pathParameters[AppRoutes
                                  .adminHouseholdIdParam] ??
                              '';
                          return _materialPage(
                            state,
                            adminHouseholdDetailBuilder?.call(context, id) ??
                                const NotYetAvailableScreen(),
                          );
                        },
                      ),
                    ],
                  ),
                  // #807: the server's own settings, a screen with nothing
                  // beneath it.
                  GoRoute(
                    path: AppRoutes._adminSettingsSegment,
                    pageBuilder: (context, state) => _materialPage(
                      state,
                      serverSettingsBuilder?.call(context) ??
                          const NotYetAvailableScreen(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.error,
        pageBuilder: (_, routerState) => _noTransitionPage(
          routerState,
          BlocBuilder<AppBootstrapCubit, AppBootstrapState>(
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
      ),
      for (final pattern in reservedDeepLinkPathPatterns)
        GoRoute(
          path: pattern,
          pageBuilder: (_, state) =>
              _materialPage(state, const NotYetAvailableScreen()),
        ),
    ],
  );
}

// go_router 18 picks a route's default page by looking for
// `material_ui`'s `MaterialApp`. The shell builds Flutter's
// `MaterialApp.router`, so go_router finds neither that nor a
// `CupertinoApp` and falls back to a [NoTransitionPage]: nothing animated,
// and iOS lost its edge swipe back (#465). Moving to `material_ui`'s
// `MaterialApp` is a whole-app migration (#637), so every route builds its
// page here instead, with the values go_router's own builder passes.
//
// Routes the user opens build a [MaterialPage], which slides or fades per
// platform and, on iOS, brings the edge swipe. Routes the bootstrap
// redirect lands on (splash, error, server-add, auth and home) keep no
// transition: the app moved there by itself, and a slide would suggest a
// back step that doesn't exist. The auth [ShellRoute]'s own page, and the
// navigation shell's (#414), are left as go_router builds them, for the
// same reason.

/// A [MaterialPage] for a route the user opens (#465).
Page<void> _materialPage(GoRouterState state, Widget child) =>
    _page(MaterialPage<void>.new, state, child);

/// A [NoTransitionPage] for a route the bootstrap redirect lands on (#465).
Page<void> _noTransitionPage(GoRouterState state, Widget child) =>
    _page(NoTransitionPage<void>.new, state, child);

/// A page that leaves the route beneath it showing, and comes and goes with
/// no transition, for a route that leaves as soon as it is built (#510,
/// #516).
Page<void> _passThroughPage(GoRouterState state, Widget child) => _page(
  ({required child, key, name, arguments, restorationId}) =>
      CustomTransitionPage<void>(
        key: key,
        name: name,
        arguments: arguments,
        restorationId: restorationId,
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        transitionsBuilder: (_, _, _, child) => child,
        child: child,
      ),
  state,
  child,
);

/// What the Add people route (#510) and the Offer games route (#516) build
/// where they have nothing to build their page from: the page's own browser
/// history entry, restored by Back or Forward once the page has closed (see
/// [EventAddAttendeeScreenBuilder]).
///
/// It draws nothing, and after its first frame leaves for the event beneath
/// it: a pop of its own page, or a `go` to the event where there is nothing
/// beneath it to pop. Under [Router.neglect], so on the web the restored
/// entry becomes the event's.
/// Reported as a new entry instead, the event would follow the restored one
/// in the history, and Back from it would come straight back here.
class _LeaveForEvent extends StatefulWidget {
  const _LeaveForEvent({required this.eventId});

  final String eventId;

  @override
  State<_LeaveForEvent> createState() => _LeaveForEventState();
}

class _LeaveForEventState extends State<_LeaveForEvent> {
  @override
  void initState() {
    super.initState();
    // After the frame that built it: the restore it is part of has settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Its own navigator, the shell's: the router pops a dialog on the
      // root navigator first, and one the event opened stays over the
      // event beneath this.
      final navigator = Navigator.of(context);
      Router.neglect(context, () {
        if (navigator.canPop()) {
          navigator.pop();
        } else {
          context.go(AppRoutes.eventDetailOf(widget.eventId));
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Builds [child]'s page with [create], from the values go_router's own
/// builder passes. Every page type goes through here, so they can't drift.
Page<void> _page(
  Page<void> Function({
    required Widget child,
    LocalKey? key,
    String? name,
    Object? arguments,
    String? restorationId,
  })
  create,
  GoRouterState state,
  Widget child,
) => create(
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  },
  restorationId: state.pageKey.value,
  child: child,
);

/// Builds the home screen for the [AppRoutes.home] route: the sections the
/// session can show (#129, #613). The menu is not home's: the navigation
/// shell holds it, above every signed-in page (#414). Always supplied by
/// `BgeApp`; returns null at navigation time when no active server is
/// resolvable (a transient pre-active state), in which case the route falls
/// back to [NotYetAvailableScreen], like the other optional-builder routes.
typedef HomeScreenBuilder = Widget? Function(BuildContext context);

/// Wraps the auth [ShellRoute] child (the auth route and the navigation
/// shell, #414) with the active server's `AuthBloc` provider and the
/// bootstrap-gate listener (#37). Supplied by `BgeApp`; when null the child
/// renders bare (tests without a scope) and the route builders fall back to
/// placeholders.
///
/// Lives at the router layer because go_router builds route widgets under
/// its own Navigator, which does not inherit providers placed above the
/// router — so the provider must be inside the route subtree, not
/// app-level.
typedef AuthScopeBuilder = Widget Function(BuildContext context, Widget child);

/// Wraps every signed-in route (#414) in the navigation shell: the menu,
/// the bar and whatever else stays put while the page beneath changes.
/// [location] is the path the visible page was reached at, after pushes,
/// pops and browser Back; [child] is the page's navigator. Supplied by
/// `BgeApp`; when null the child renders bare (tests without a shell).
///
/// The shell sits inside the auth scope (#145), so it can read the
/// `AuthBloc`; `/auth` itself stays outside it.
typedef NavigationShellBuilder = Widget Function(
  BuildContext context,
  String location,
  Widget child,
);

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
