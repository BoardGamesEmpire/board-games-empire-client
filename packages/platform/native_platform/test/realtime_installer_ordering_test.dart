import 'package:di/di.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_platform/native_platform.dart';

/// Native's user-scope list holds the realtime installer (#473), once, after
/// the rehydrator, so the session owns its socket connection and the search's
/// stream source.
///
/// The installer's own behaviour is tested in `dio_network`. The web list has
/// its own equivalent in
/// `packages/platform/web/test/web_user_scope_installers_test.dart`.
void main() {
  test('has one RealtimeInstaller, after the rehydrator', () {
    final installers = buildNativeUserScopeInstallers();

    expect(installers.whereType<RealtimeInstaller>(), hasLength(1));
    expect(
      installers.indexWhere((i) => i is RealtimeInstaller),
      greaterThan(
        installers.indexWhere((i) => i is SessionRehydratorInstaller),
      ),
    );
  });
}
