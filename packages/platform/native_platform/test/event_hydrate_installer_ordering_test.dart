import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_platform/native_platform.dart';

/// Native's user-scope list holds the event hydrate installer (#496), in an
/// order its dependencies make load-bearing.
///
/// The installer's own behaviour is tested where it lives
/// (`packages/features/events/test/sync/event_hydrate_installer_test.dart`).
/// What stays here is the part about *this* composition root. The web list has
/// its own equivalent in
/// `packages/platform/web/test/web_user_scope_installers_test.dart`.
void main() {
  test('the list holds the event hydrate installer once', () {
    expect(
      buildNativeUserScopeInstallers().whereType<EventHydrateInstaller>(),
      hasLength(1),
    );
  });

  test('the event hydrate installer runs after the one registering the '
      'repository it resolves', () {
    final installers = buildNativeUserScopeInstallers();

    final storage = installers.indexWhere(
      (i) => i is UserSessionScopeInstaller,
    );
    final hydrate = installers.indexWhere((i) => i is EventHydrateInstaller);

    // EventRepository is registered by the storage installer, and installers
    // run in list order.
    expect(storage, isNonNegative);
    expect(hydrate, greaterThan(storage));
  });

  test('the rehydrator installer runs before the event hydrate that registers '
      'with it', () {
    final installers = buildNativeUserScopeInstallers();

    final rehydrator = installers.indexWhere(
      (i) => i is SessionRehydratorInstaller,
    );
    final hydrate = installers.indexWhere((i) => i is EventHydrateInstaller);

    expect(rehydrator, isNonNegative);
    expect(hydrate, greaterThan(rehydrator));
  });
}
