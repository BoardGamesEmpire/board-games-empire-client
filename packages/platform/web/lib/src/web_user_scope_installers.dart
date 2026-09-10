import 'package:di/di.dart' show SessionRehydratorInstaller;
import 'package:drift_storage/drift_storage.dart'
    show UserSessionScopeInstaller;
import 'package:household/household.dart' show HouseholdHydrateInstaller;
import 'package:interfaces/orchestration.dart' show UserScopeInstaller;

/// The per-user session-scope installers for web (#137), run on every
/// sign-in by `UserSessionScope.activate()` and disposed on any transition
/// out of the authenticated state.
///
/// The native counterpart is `buildNativeUserScopeInstallers`, and the
/// overlap is the point: every entry here is platform-neutral code, so web
/// runs the *same* installers native does rather than parallel
/// implementations of the same three repositories and the same hydrate
/// wiring. That is what #244 is for, and what #287's barrel split made
/// possible — a web target imports `drift_storage.dart` and gets the
/// repositories without the `dart:io` executor half.
///
/// Order is structural, exactly as on native. [SessionRehydratorInstaller]
/// runs **first**: it registers the #302 re-hydrate seam that later
/// hydrating installers register themselves with, and an installer can only
/// resolve what a predecessor registered. [HouseholdHydrateInstaller] runs
/// **last** for the same reason: it resolves the `HouseholdRepository` the
/// tier above it registers.
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
/// This lives on the VM-compilable side of the package split so its
/// membership can be asserted without a browser, the way native's is.
/// `buildWebServerScope` — which is browser-only, because it composes the
/// wasm executor — passes it to `bootstrapWebServerScope`.
List<UserScopeInstaller> buildWebUserScopeInstallers() => const [
  SessionRehydratorInstaller(),
  UserSessionScopeInstaller(),
  HouseholdHydrateInstaller(),
];
