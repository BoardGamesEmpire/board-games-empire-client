import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
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

  test('the user-session scope is wired in the USER tier (#129/#135)', () {
    final userInstallers = buildNativeUserScopeInstallers();

    // Must be present, or create-household and the collection feature
    // dead-end: the user-session scope is what registers
    // HouseholdRepository and GameCollectionRepository on sign-in (#150).
    expect(userInstallers.whereType<UserSessionScopeInstaller>(), isNotEmpty);
  });

  test('no per-server installer is ALSO a user-scope installer — '
      'registering per-user services there resurrects the #135 bug class', () {
    final installers = buildNativeServerScopeInstallers(
      executorFactory: _MockExecutorFactory(),
      keyService: _MockKeyService(),
    );

    // A per-server registration of a per-user repository would live for the
    // whole server scope: singletons surviving a same-server user change,
    // live watch* queries emitting the prior user's rows after sign-out.
    // This is the regression the #129 heads-up on the issue warned about.
    //
    // Asserted against the *interface*, not UserSessionScopeInstaller: that
    // concrete type cannot appear in a List<ServerScopeInstaller> at all
    // (the two installer interfaces are unrelated, so adding it would not
    // compile), which made the previous assertion unfalsifiable. A class
    // implementing both interfaces — the way this bug class would actually
    // return — does type-check into this list, and fails here.
    expect(installers.whereType<UserScopeInstaller>(), isEmpty);
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
