import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:native_platform/native_platform.dart';

/// Native's user-scope list holds the household hydrate installer, in an order
/// its dependencies make load-bearing.
///
/// The installer's own behaviour is tested where it now lives
/// (`packages/features/household/test/sync/household_hydrate_installer_test.dart`,
/// #125). What stays here is the part that is genuinely about *this*
/// composition root — that the list contains the installer at all, and that
/// nothing it resolves is registered after it. The web list has its own
/// equivalent in `packages/platform/web/test/web_user_scope_installers_test.dart`.
void main() {
  test('the hydrate installer runs after the one registering the repository '
      'it resolves', () {
    final installers = buildNativeUserScopeInstallers();

    final storage = installers.indexWhere(
      (i) => i is UserSessionScopeInstaller,
    );
    final hydrate = installers.indexWhere(
      (i) => i is HouseholdHydrateInstaller,
    );

    // Installers run in list order and may resolve what a predecessor
    // registered. HouseholdRepository is registered by the storage installer,
    // so ordering here is a real constraint, not cosmetics.
    expect(storage, isNonNegative);
    expect(hydrate, greaterThan(storage));
  });

  test('the rehydrator installer runs before the hydrate that registers with '
      'it', () {
    final installers = buildNativeUserScopeInstallers();

    final rehydrator = installers.indexWhere(
      (i) => i is SessionRehydratorInstaller,
    );
    final hydrate = installers.indexWhere(
      (i) => i is HouseholdHydrateInstaller,
    );

    expect(rehydrator, isNonNegative);
    expect(hydrate, greaterThan(rehydrator));
  });
}
