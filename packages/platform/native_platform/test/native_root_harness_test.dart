// The probe for the native root harness (#435): the real
// `NativePlatformBootstrap`, with only its external boundaries faked (see
// `NativeRootHarness`), can boot, add a server, sign in through the real
// `AuthRepositoryImpl`, and come back from a restart. Kept as the harness's
// own check, so a suite built on it fails here first when the root stops
// running under these fakes.
//
// Plain `test()`, not `testWidgets`: drift and the real async work under the
// root need real time, and the widget tester's fake async would stall them.

import 'dart:async';

import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';

import 'support/native_root_harness.dart';

void main() {
  group('NativeRootHarness', () {
    late NativeRootHarness harness;

    setUp(() async {
      harness = await NativeRootHarness.create();
      addTearDown(harness.dispose);
    });

    test(
      'boots the real root with no saved server and sends nothing',
      () async {
        await harness.boot();

        expect(harness.orchestrator.activeServerId, isNull);
        expect(harness.server.requests, isEmpty);
        expect(harness.escapedRequests, isEmpty);
      },
    );

    test(
      'adds a server and activates its scope without sending a request',
      () async {
        await harness.boot();

        await harness.addServer();

        expect(harness.active.state, ServerContextState.active);
        expect(harness.server.requests, isEmpty);
        expect(harness.escapedRequests, isEmpty);
      },
    );

    test('signs in through the real auth repository', () async {
      await harness.boot();
      await harness.addServer();

      await harness.signIn();

      final auth = harness.container.get<AuthRepository>();
      expect(auth, isA<AuthRepositoryImpl>());
      expect(
        auth.currentAuthState,
        isA<AuthStateAuthenticated>().having(
          (state) => state.session.user.id,
          'user id',
          NativeRootHarness.userId,
        ),
      );
      expect(harness.server.requestsTo('POST', '/sign-in/email'), hasLength(1));
      expect(harness.server.requestsTo('GET', '/get-session'), hasLength(1));
    });

    test(
      'a second boot over the same files restores the server and its session',
      () async {
        await harness.boot();
        await harness.addServer();
        await harness.signIn();

        await harness.shutdown();
        await harness.boot();
        harness.server.clear();
        await harness.restoreSession();

        expect(
          harness.server.requests,
          isEmpty,
          reason: 'the session came from the keychain, not the server',
        );
        expect(
          harness.container.get<AuthRepository>().currentAuthState,
          isA<AuthStateAuthenticated>().having(
            (state) => state.session.user.id,
            'user id',
            NativeRootHarness.userId,
          ),
        );
      },
    );

    test(
      'pollUntil fails at its deadline on a check that never answers',
      () async {
        await expectLater(
          harness.pollUntil(
            () => Completer<bool>().future,
            describe: () => 'the check never answered',
            timeout: const Duration(milliseconds: 50),
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              'the check never answered',
            ),
          ),
        );
      },
      // Without the bound the check hangs: fail in seconds, not at the
      // runner's default.
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });
}
