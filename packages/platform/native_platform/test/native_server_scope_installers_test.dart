import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_platform/native_platform.dart';

class _MockKeyService extends Mock implements EncryptionKeyService {}

class _MockExecutorFactory extends Mock implements EncryptedExecutorFactory {}

void main() {
  test('native per-server boot list wires the household scope, last '
      '(#128/#129)', () {
    // Pure composition: installers store their collaborators and defer all
    // I/O to install(), so unstubbed mocks are enough to build the list —
    // no encrypted database, keychain, or filesystem is touched here.
    final installers = buildNativeServerScopeInstallers(
      executorFactory: _MockExecutorFactory(),
      keyService: _MockKeyService(),
    );

    // Must be present, or create-household dead-ends on NotYetAvailableScreen
    // (the scope is what registers HouseholdRepository / -RemoteDataSource).
    expect(installers.whereType<HouseholdScopeInstaller>(), isNotEmpty);

    // Must be LAST: install() reads the per-server database and auth
    // repository that the storage and network installers register first.
    // This assertion is the coverage that makes the #128 eager-vs-lazy
    // regression fail loudly instead of shipping green.
    expect(installers.last, isA<HouseholdScopeInstaller>());
  });
}
