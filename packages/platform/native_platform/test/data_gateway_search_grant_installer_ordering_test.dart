import 'package:access/access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:native_platform/native_platform.dart';

/// Native's user-scope list holds the installer that registers the session's
/// memory of a DataGateway refusal (#795) once, right after
/// [CallerAccessInstaller], where the web list holds it too.
///
/// Its place isn't load-bearing, as it resolves nothing, but it sits with the
/// other installers the search reads, and both lists keep it at the same one.
///
/// The installer's own behaviour is tested where it lives, in the catalog
/// package. The web list has its own equivalent in
/// `packages/platform/web/test/web_user_scope_installers_test.dart`.
void main() {
  test('has one DataGatewaySearchGrantInstaller, right after the '
      'CallerAccessInstaller', () {
    final installers = buildNativeUserScopeInstallers();

    expect(
      installers.whereType<DataGatewaySearchGrantInstaller>(),
      hasLength(1),
    );
    expect(
      installers.indexWhere((i) => i is DataGatewaySearchGrantInstaller),
      installers.indexWhere((i) => i is CallerAccessInstaller) + 1,
    );
  });
}
