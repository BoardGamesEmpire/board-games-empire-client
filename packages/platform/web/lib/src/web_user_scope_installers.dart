import 'package:access/access.dart' show CallerAccessInstaller;
import 'package:data_gateway/data_gateway.dart' show dataGatewayResourceTypes;
import 'package:di/di.dart' show SessionRehydratorInstaller;
import 'package:dio_network/dio_network.dart' show RealtimeInstaller;
import 'package:drift_storage/drift_storage.dart'
    show UserSessionScopeInstaller;
import 'package:events/events.dart' show EventHydrateInstaller;
import 'package:game_catalog/game_catalog.dart'
    show DataGatewaySearchGrantInstaller, catalogResourceTypes;
import 'package:game_collection/game_collection.dart'
    show GameCollectionHydrateInstaller;
import 'package:household/household.dart'
    show HouseholdHydrateInstaller, householdAdminResourceTypes;
import 'package:interfaces/orchestration.dart' show UserScopeInstaller;
import 'package:server_settings/server_settings.dart'
    show serverSettingsResourceTypes;
import 'package:sync_queue/sync_queue.dart'
    show SyncQueueDrainInstaller, SyncSenderInstaller;
import 'package:web_platform/src/storage/persistent_storage_request.dart';

/// The per-user session-scope installers for web (#137), run on every
/// sign-in by `UserSessionScope.activate()` and disposed on any transition
/// out of the authenticated state.
///
/// The native counterpart is `buildNativeUserScopeInstallers`, and the
/// overlap is the point: every entry here is platform-neutral code, so web
/// runs the *same* installers native does rather than parallel
/// implementations of the same repositories, the event repository (#496)
/// among them, and the same hydrate wiring. That is what #244 is for, and
/// what #287's barrel split made possible — a web target imports
/// `drift_storage.dart` and gets the repositories without the `dart:io`
/// executor half.
///
/// Order is structural, exactly as on native. [SessionRehydratorInstaller]
/// runs **first**: it registers the #302 re-hydrate seam that later
/// hydrating installers register themselves with, and an installer can only
/// resolve what a predecessor registered. The hydrate installers run after
/// the tier above them for the same reason: [HouseholdHydrateInstaller]
/// resolves the `HouseholdRepository` it registers,
/// [GameCollectionHydrateInstaller] the `GameCollectionRepository` (#259), and
/// [EventHydrateInstaller] the `EventRepository` (#496).
///
/// [RealtimeInstaller] is shared with native (#473) and runs right after the
/// rehydrator. It registers the session's socket connection and the games
/// search stream source over it, only when the server scope has a
/// `RealtimeEndpoint` (`registerServerNetworkWeb` registers one); otherwise
/// search goes over REST. It never throws or waits, and connects nothing
/// until a screen takes a lease. It needs only that endpoint, which the user
/// scope falls through to, so it can sit this early, ahead of every
/// installer that might one day lease the socket.
///
/// The resources these installers need — the `ServerDatabase` (#288), the
/// skew-corrected `ClockService` (#118) and the `AuthRepository` — live in
/// the origin scope, which the user-scope container view resolves by falling
/// through. Nothing here supplies them.
///
/// **The hydrate installer is native's own** (#125), moved out of
/// `native_platform` into the household feature so both lists could hold the
/// one instance rather than a copy each. It waited for #125: it needs a
/// `HouseholdRemoteDataSource`, which `registerServerNetworkWeb` now
/// registers into the origin scope, and adding it before the remote existed
/// would have published a permanently-idle `HouseholdHydrationStatus` — a
/// claim the list screen cannot see through.
///
/// The re-hydrate triggers it registers with need nothing web-specific:
/// `SessionRehydrateTrigger` lives in `app_shell` and is driven by
/// connectivity edges and app-lifecycle resumes on both platforms.
///
/// [CallerAccessInstaller] is shared with native (#456): one unawaited ask
/// for what the caller may do with the DataGateway types, registered as the
/// `CallerAccessRepository` that the DataGateway screens, home's Admin entry
/// and connect card, and the search's DataGateway names read. It resolves the
/// `UserRemoteDataSource` that `registerServerNetworkWeb` registers in the
/// origin scope, and registers its re-ask with the rehydrator above, so it
/// runs after both that and [UserSessionScopeInstaller].
///
/// [DataGatewaySearchGrantInstaller] is shared with native (#795), and runs
/// after [CallerAccessInstaller]. It registers the session's memory of
/// whether the server refused the DataGateways to this user, which the
/// search screen's bloc reads, so a refusal is asked once a session and
/// forgotten when the session ends. It resolves nothing, so it never throws
/// or waits, and its place is for reading order: it sits with the other
/// installers the search reads.
///
/// [SyncSenderInstaller] registers the sender the create screen's inline
/// send goes through (#121), over the repositories above it. On web it asks
/// before each delivery whether the session is still this user's, since
/// another tab can move the shared cookie (#432).
///
/// [SyncQueueDrainInstaller] runs last, as on native: it starts the drain over
/// that sender, so a queued write that could not be sent goes out on a later
/// pass, on the session's re-hydrate triggers. Unlike native, each pass runs
/// under the Web Lock the server scope registers
/// (`bge.sync_drain.<serverId>.<userId>`), so one tab at a time drains each
/// server database and user (#447). Where the browser has no Web Locks it
/// drains without one and logs a warning.
///
/// The household, collection and event hydrates ask the same question before
/// each pass (#432).
///
/// [PersistentStorageRequestInstaller] is web's own and runs last. It
/// resolves nothing and depends on nothing, so its place in the list is not
/// structural. It starts [requestPersistentStorage], the browser's ask for
/// `navigator.storage.persist()`, when a user session starts rather than
/// before one, because by then the user has shown they mean to use the app
/// and data the server does not have yet starts to build up, and Firefox
/// prompts for the grant (#320). A session restored at startup starts one
/// too, so a signed-in user is asked on each page load until the browser
/// has answered for good. It never throws or waits.
/// [requestPersistentStorage] is the caller's once-per-page-load function, so
/// a sign-out and a sign-in do not ask again.
///
/// This lives on the VM-compilable side of the package split so its
/// membership can be asserted without a browser, the way native's is.
/// `buildWebServerScope` — which is browser-only, because it composes the
/// wasm executor — passes it to `bootstrapWebServerScope`, along with the
/// browser call [requestPersistentStorage] stands for.
List<UserScopeInstaller> buildWebUserScopeInstallers({
  required Future<void> Function() requestPersistentStorage,
}) => [
  const SessionRehydratorInstaller(),
  const RealtimeInstaller(),
  const UserSessionScopeInstaller(),
  const HouseholdHydrateInstaller(),
  const GameCollectionHydrateInstaller(),
  const EventHydrateInstaller(),
  const CallerAccessInstaller(
    resourceTypes: {
      ...catalogResourceTypes,
      ...dataGatewayResourceTypes,
      ...householdAdminResourceTypes,
      ...serverSettingsResourceTypes,
    },
  ),
  const DataGatewaySearchGrantInstaller(),
  const SyncSenderInstaller(),
  const SyncQueueDrainInstaller(),
  PersistentStorageRequestInstaller(requestPersistentStorage),
];
