import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

import 'package:web_network/src/auth/provider_sign_in_bindings.dart';
import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// How the network registration hands the repository the browser half of a
/// provider sign-in (#583).
void main() {
  late DependencyContainerImpl container;

  setUp(() => container = DependencyContainerImpl());

  tearDown(() async => container.dispose());

  AuthRepository register({WebProviderSignInBindings? providerSignIn}) {
    registerServerNetworkWeb(
      container: container,
      identity: testServerIdentity(),
      originProvider: () => 'https://bge.example.com',
      providerSignIn: providerSignIn,
    );
    return container.get<AuthRepository>();
  }

  test('the registered repository signs in through a provider with the '
      'browser bindings, and reads their startup return', () {
    final repository = register(
      providerSignIn: WebProviderSignInBindings(
        leavePageFor: (_, _) {},
        startupReturn: const WebProviderSignInReturn(
          errorCode: 'REGISTRATION_DISABLED',
        ),
      ),
    );

    expect(
      repository.providerSignInAvailability,
      isA<ProviderSignInAvailable>(),
    );
    expect(
      repository.takeProviderSignInReturn()?.reason,
      ProviderSignInFailureReason.registrationDisabled,
    );
  });

  test('without the browser bindings the registered repository cannot sign '
      'in through a provider', () {
    final repository = register();

    expect(
      repository.providerSignInAvailability,
      isA<ProviderSignInUnsupportedDevice>(),
    );
  });
}
