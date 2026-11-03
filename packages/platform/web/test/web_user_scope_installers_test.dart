// The list is platform-neutral by construction — both entries come from
// packages that compile for the VM — which is exactly why its membership can
// be asserted here rather than only in a browser suite (#137).
@TestOn('vm')
library;

import 'package:access/access.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:web_platform/web.dart';

void main() {
  group('buildWebUserScopeInstallers', () {
    test('installs the shared user-session tier, re-hydrate seam first', () {
      final installers = buildWebUserScopeInstallers();

      // Order is structural: the re-hydrate registry has to exist before any
      // hydrating installer can register itself with it (#302), and each
      // hydrate installer resolves a repository the tier above it registers.
      expect(installers, hasLength(9));
      expect(installers[0], isA<SessionRehydratorInstaller>());
      expect(installers[1], isA<UserSessionScopeInstaller>());
      expect(installers[2], isA<HouseholdHydrateInstaller>());
      expect(installers[3], isA<GameCollectionHydrateInstaller>());
      expect(installers[4], isA<EventHydrateInstaller>());
      expect(installers[5], isA<CallerAccessInstaller>());
      expect(installers[6], isA<DataGatewayAccessInstaller>());
      expect(installers[7], isA<SyncSenderInstaller>());
      expect(installers[8], isA<SyncQueueDrainInstaller>());
    });

    test('runs the same DataGateway access installer native does, after the '
        'rehydrator it registers with (#41)', () {
      final installers = buildWebUserScopeInstallers();

      expect(installers.whereType<DataGatewayAccessInstaller>(), hasLength(1));
      expect(
        installers.indexWhere((i) => i is DataGatewayAccessInstaller),
        greaterThan(
          installers.indexWhere((i) => i is SessionRehydratorInstaller),
        ),
      );
    });

    test('has one CallerAccessInstaller, after the rehydrator, asking for the '
        'DataGateway types (#456)', () {
      final installers = buildWebUserScopeInstallers();

      final callerAccess = installers.whereType<CallerAccessInstaller>();

      expect(callerAccess, hasLength(1));
      expect(
        installers.indexWhere((i) => i is CallerAccessInstaller),
        greaterThan(
          installers.indexWhere((i) => i is SessionRehydratorInstaller),
        ),
      );
      expect(
        callerAccess.single.resourceTypes,
        contains(ResourceType.dataGateway),
      );
    });

    test('holds the sender and the drain over it, drain last (#447)', () {
      // The create screen sends through the sender on both platforms, and the
      // drain over it sends what an inline send could not. On web the drain
      // runs each pass under the Web Lock the server scope registers, so it
      // composes after the sender it wraps.
      final installers = buildWebUserScopeInstallers();

      expect(installers.whereType<SyncSenderInstaller>(), hasLength(1));
      expect(installers.whereType<SyncQueueDrainInstaller>(), hasLength(1));
      expect(
        installers.indexWhere((i) => i is SyncQueueDrainInstaller),
        greaterThan(installers.indexWhere((i) => i is SyncSenderInstaller)),
      );
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

    test('runs the same collection hydrate installer native does, after the '
        'tiers it depends on (#259)', () {
      final installers = buildWebUserScopeInstallers();

      final rehydrator = installers.indexWhere(
        (i) => i is SessionRehydratorInstaller,
      );
      final storage = installers.indexWhere(
        (i) => i is UserSessionScopeInstaller,
      );
      final hydrate = installers.indexWhere(
        (i) => i is GameCollectionHydrateInstaller,
      );

      expect(
        installers.whereType<GameCollectionHydrateInstaller>(),
        hasLength(1),
      );
      expect(hydrate, greaterThan(storage));
      expect(hydrate, greaterThan(rehydrator));
    });

    test('runs the same event hydrate installer native does, after the tiers '
        'it depends on (#496)', () {
      final installers = buildWebUserScopeInstallers();

      final rehydrator = installers.indexWhere(
        (i) => i is SessionRehydratorInstaller,
      );
      final storage = installers.indexWhere(
        (i) => i is UserSessionScopeInstaller,
      );
      final hydrate = installers.indexWhere((i) => i is EventHydrateInstaller);

      // Native's equivalent is
      // `native_platform/test/event_hydrate_installer_ordering_test.dart`.
      expect(installers.whereType<EventHydrateInstaller>(), hasLength(1));
      expect(hydrate, greaterThan(storage));
      expect(hydrate, greaterThan(rehydrator));
    });
  });
}
