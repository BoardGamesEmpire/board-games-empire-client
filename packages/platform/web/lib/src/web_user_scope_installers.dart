import 'package:di/di.dart' show SessionRehydratorInstaller;
import 'package:drift_storage/drift_storage.dart'
    show UserSessionScopeInstaller;
import 'package:interfaces/orchestration.dart' show UserScopeInstaller;

/// The per-user session-scope installers for web (#137), run on every
/// sign-in by `UserSessionScope.activate()` and disposed on any transition
/// out of the authenticated state.
///
/// The native counterpart is `buildNativeUserScopeInstallers`, and the
/// overlap is the point: both entries here are platform-neutral code, so web
/// runs the *same* `UserSessionScopeInstaller` native does rather than a
/// parallel implementation of the same three repositories. That is what #244
/// is for, and what #287's barrel split made possible — a web target imports
/// `drift_storage.dart` and gets the repositories without the `dart:io`
/// executor half.
///
/// Order is structural, exactly as on native. [SessionRehydratorInstaller]
/// runs **first**: it registers the #302 re-hydrate seam that later
/// hydrating installers register themselves with, and an installer can only
/// resolve what a predecessor registered.
///
/// The resources these installers need — the `ServerDatabase` (#288), the
/// skew-corrected `ClockService` (#118) and the `AuthRepository` — live in
/// the origin scope, which the user-scope container view resolves by falling
/// through. Nothing here supplies them.
///
/// **No hydrate installer yet**, deliberately. Native's
/// `HouseholdHydrateInstaller` needs a `HouseholdRemoteDataSource`, and web
/// registers none until #125; its absence already reads as "no drain on this
/// composition" everywhere that matters — the list screen treats a missing
/// `HouseholdHydrationStatus` as settled, and the create route is gated on
/// the remote. Adding the installer here before the remote exists would
/// register a status that is permanently idle, which is a claim the screen
/// cannot see through.
///
/// This lives on the VM-compilable side of the package split so its
/// membership can be asserted without a browser, the way native's is.
/// `buildWebServerScope` — which is browser-only, because it composes the
/// wasm executor — passes it to `bootstrapWebServerScope`.
List<UserScopeInstaller> buildWebUserScopeInstallers() => const [
  SessionRehydratorInstaller(),
  UserSessionScopeInstaller(),
];
