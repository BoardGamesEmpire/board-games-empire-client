// The list is platform-neutral by construction — both entries come from
// packages that compile for the VM — which is exactly why its membership can
// be asserted here rather than only in a browser suite (#137).
@TestOn('vm')
library;

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_platform/web.dart';

void main() {
  group('buildWebUserScopeInstallers', () {
    test('installs the shared user-session tier, re-hydrate seam first', () {
      final installers = buildWebUserScopeInstallers();

      // Order is structural: the re-hydrate registry has to exist before any
      // hydrating installer can register itself with it (#302).
      expect(installers, hasLength(2));
      expect(installers[0], isA<SessionRehydratorInstaller>());
      expect(installers[1], isA<UserSessionScopeInstaller>());
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

    test('carries no household hydrate installer yet', () {
      // Web registers no HouseholdRemoteDataSource until #125, and a hydrate
      // installer without one would publish a permanently-idle hydration
      // status the list screen cannot see through.
      expect(
        buildWebUserScopeInstallers().map((i) => i.runtimeType.toString()),
        isNot(contains(contains('Hydrate'))),
      );
    });
  });
}
