import 'package:access/access.dart';
import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';

/// Native's user-scope list holds the caller-access installer (#456), once,
/// asking about the DataGateway types, after the rehydrator it registers its
/// re-ask with and the user-session tier.
///
/// The installer's own behaviour is tested where it lives
/// (`packages/core/access/test/caller_access_installer_test.dart`). The web
/// list has its own equivalent in
/// `packages/platform/web/test/web_user_scope_installers_test.dart`.
void main() {
  test('has one CallerAccessInstaller, asking for the DataGateway, '
      'household and system setting types (#807)', () {
    final callerAccess = buildNativeUserScopeInstallers()
        .whereType<CallerAccessInstaller>();

    expect(callerAccess, hasLength(1));
    expect(
      callerAccess.single.resourceTypes,
      containsAll([
        ResourceType.dataGateway,
        ResourceType.household,
        ResourceType.systemSetting,
      ]),
    );
  });

  test('the installer runs after the rehydrator and the user-session tier', () {
    final installers = buildNativeUserScopeInstallers();

    final rehydrator = installers.indexWhere(
      (i) => i is SessionRehydratorInstaller,
    );
    final session = installers.indexWhere(
      (i) => i is UserSessionScopeInstaller,
    );
    final callerAccess = installers.indexWhere(
      (i) => i is CallerAccessInstaller,
    );

    expect(rehydrator, isNonNegative);
    expect(session, isNonNegative);
    expect(callerAccess, greaterThan(rehydrator));
    expect(callerAccess, greaterThan(session));
  });
}
