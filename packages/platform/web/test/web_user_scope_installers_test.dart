// The list is platform-neutral by construction — both entries come from
// packages that compile for the VM — which is exactly why its membership can
// be asserted here rather than only in a browser suite (#137).
@TestOn('vm')
library;

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:web_platform/web.dart';

void main() {
  group('buildWebUserScopeInstallers', () {
    test('installs the shared user-session tier, re-hydrate seam first', () {
      final installers = buildWebUserScopeInstallers();

      // Order is structural: the re-hydrate registry has to exist before any
      // hydrating installer can register itself with it (#302), and the
      // hydrate installer resolves the repository the tier above it registers.
      expect(installers, hasLength(3));
      expect(installers[0], isA<SessionRehydratorInstaller>());
      expect(installers[1], isA<UserSessionScopeInstaller>());
      expect(installers[2], isA<HouseholdHydrateInstaller>());
    });

    test('runs the same installer native does, not a web copy of it', () {
      // The #244 property worth pinning: `UserSessionScopeInstaller` is the
      // platform-neutral one from `drift_storage`, so the sync queue,
      // household and collection repositories are wired identically on both
      // platforms. A web-specific reimplementation is the divergence this
      // epic exists to close.
      expect(
        buildWebUserScopeInstallers().whereType<UserSessionScopeInstaller>(),
        hasLength(1),
      );
    });

    test('runs the same hydrate installer native does, not a web copy '
        '(#125)', () {
      // The other half of the property above. `HouseholdHydrateInstaller`
      // moved out of `native_platform` into the household feature so both
      // lists could hold it; a `WebHouseholdHydrateInstaller` beside it would
      // be two copies of the #269 status window, the #302 re-hydrate
      // registration and the #300 staleness closure, free to drift apart.
      expect(
        buildWebUserScopeInstallers().whereType<HouseholdHydrateInstaller>(),
        hasLength(1),
      );
    });

    test('the hydrate installer runs after the tier registering the '
        'repository it resolves', () {
      final installers = buildWebUserScopeInstallers();

      final storage = installers.indexWhere(
        (i) => i is UserSessionScopeInstaller,
      );
      final hydrate = installers.indexWhere(
        (i) => i is HouseholdHydrateInstaller,
      );

      // Native's equivalent is
      // `native_platform/test/household_hydrate_installer_ordering_test.dart`.
      expect(storage, isNonNegative);
      expect(hydrate, greaterThan(storage));
    });
  });
}
