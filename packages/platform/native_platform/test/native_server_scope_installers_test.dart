import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_platform/native_platform.dart';

class _MockKeyService extends Mock implements EncryptionKeyService {}

class _MockExecutorFactory extends Mock implements EncryptedExecutorFactory {}

void main() {
  // Pure composition: installers store their collaborators and defer all
  // I/O to install(), so unstubbed mocks are enough to build the lists —
  // no encrypted database, keychain, or filesystem is touched here.
  //
  // The factory's pass-through of both lists into ServerContextImpl isn't
  // asserted at this level (the context doesn't expose its installer
  // lists); the tier *behavior* — install-on-activate for the server list,
  // install-on-sign-in for the user list — is covered by the context and
  // acceptance suites in core/di and drift_storage (#135).

  test('the household scope is wired in the USER tier (#129/#135)', () {
    final userInstallers = buildNativeUserScopeInstallers();

    // Must be present, or create-household dead-ends: the user-session
    // scope is what registers HouseholdRepository on sign-in.
    expect(userInstallers.whereType<HouseholdScopeInstaller>(), isNotEmpty);
  });

  test('the household scope is ABSENT from the per-server tier — '
      'registering it there resurrects the #135 bug class', () {
    final installers = buildNativeServerScopeInstallers(
      executorFactory: _MockExecutorFactory(),
      keyService: _MockKeyService(),
    );

    // A per-server household registration would live for the whole server
    // scope: per-user singletons surviving a same-server user change, live
    // watch* queries emitting the prior user's rows after sign-out. This
    // is the regression the #129 heads-up on the issue warned about.
    expect(installers.whereType<HouseholdScopeInstaller>(), isEmpty);
  });

  test('the per-server tier keeps storage before network', () {
    final installers = buildNativeServerScopeInstallers(
      executorFactory: _MockExecutorFactory(),
      keyService: _MockKeyService(),
    );

    // NetworkScopeInstaller's registrations are resolved by later tiers;
    // StorageScopeInstaller opens the database everything else sits on.
    expect(installers.first, isA<StorageScopeInstaller>());
    expect(installers, hasLength(2));
  });
}
