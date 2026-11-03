import 'package:access/access.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';

/// Native's user-scope list holds the DataGateway access installer (#41),
/// after the rehydrator it registers with.
///
/// The installer's own behaviour is tested where it lives
/// (`packages/features/data_gateway/test/access/`). The web list has its own
/// equivalent in `packages/platform/web/test/web_user_scope_installers_test.dart`.
void main() {
  test('holds the access installer, once', () {
    expect(
      buildNativeUserScopeInstallers().whereType<DataGatewayAccessInstaller>(),
      hasLength(1),
    );
  });

  test('the access installer runs after the rehydrator it registers with', () {
    final installers = buildNativeUserScopeInstallers();

    final rehydrator = installers.indexWhere(
      (i) => i is SessionRehydratorInstaller,
    );
    final access = installers.indexWhere(
      (i) => i is DataGatewayAccessInstaller,
    );

    expect(rehydrator, isNonNegative);
    expect(access, greaterThan(rehydrator));
  });

  test('has one CallerAccessInstaller, after the rehydrator, asking for the '
      'DataGateway types (#456)', () {
    final installers = buildNativeUserScopeInstallers();

    final rehydrator = installers.indexWhere(
      (i) => i is SessionRehydratorInstaller,
    );
    final callerAccess = installers.whereType<CallerAccessInstaller>();

    expect(callerAccess, hasLength(1));
    expect(
      installers.indexWhere((i) => i is CallerAccessInstaller),
      greaterThan(rehydrator),
    );
    expect(
      callerAccess.single.resourceTypes,
      contains(ResourceType.dataGateway),
    );
  });
}
