import 'dart:ui';

import 'package:app_shell/app_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import '../support/fake_platform_bootstrap.dart';
import '../support/spy_root_container.dart';

/// Red-phase tests for `runBgeApp`'s root-container leg (issue #72).
///
/// Design decisions pinned here (see #72 for rationale):
///
/// - **The root container** (device-global `DependencyContainer`) is
///   acquired via `PlatformBootstrap.createRootContainer()` — platform
///   composition roots own composition; `main.dart` stays thin.
/// - **Sequencing.** Built exactly once, *before* the error hooks are
///   installed (#69 resolves the crash reporter from it) and before the
///   failure-prone platform `initialize()` — so device-global services
///   (client version, feedback) exist even on a failed boot.
/// - **Belt-and-braces guard.** `createRootContainer` implementations
///   must not throw (they register degraded values instead), and
///   `runBgeApp` additionally guards the call: on a throw it breadcrumbs
///   at error level (`bge.shell.root_container`) and proceeds on a
///   *functional* empty fallback container — error capture is never
///   coupled to root-container success.
/// - **Ownership.** `runBgeApp` has no teardown point of its own, so
///   `BgeApp` owns the container's lifecycle
///   (`disposeRootContainerOnDispose: true`), mirroring
///   `closeBootstrapCubitOnDispose`.
/// - **Widget-tree exposure is deliberately deferred** (#72 decision):
///   nothing reads the container from `BuildContext` yet; the first
///   widget consumer adds a thin provider when it actually needs one.
/// - **`hydratedStorageInitializer` passthrough.** `runBgeApp` forwards
///   an injectable initializer to the cubit (production default: the
///   cubit's real one) purely so these tests stay off real Hive IO —
///   the same seam `AppBootstrapCubit` already exposes.
///
/// `runBgeApp` mutates process globals (`FlutterError.onError`,
/// `PlatformDispatcher.onError`, `ErrorWidget.builder`), so every test
/// saves and restores all three — leaking one corrupts the suite and
/// trips the test binding's restoration checks.
class _Marker {}

void main() {
  late FlutterExceptionHandler? savedFlutterOnError;
  late ErrorCallback? savedDispatcherOnError;
  late ErrorWidgetBuilder savedErrorWidgetBuilder;

  setUp(() {
    savedFlutterOnError = FlutterError.onError;
    savedDispatcherOnError = PlatformDispatcher.instance.onError;
    savedErrorWidgetBuilder = ErrorWidget.builder;
  });

  tearDown(() async {
    FlutterError.onError = savedFlutterOnError;
    PlatformDispatcher.instance.onError = savedDispatcherOnError;
    ErrorWidget.builder = savedErrorWidgetBuilder;
    await ShellObservability.reset();
  });

  /// Boots via the real [runBgeApp], then pumps twice: once to build the
  /// tree, once to let the unawaited cubit bootstrap (injected no-op
  /// hydrated init → platform initialize) run to completion.
  Future<void> boot(
    WidgetTester tester,
    FakePlatformBootstrap bootstrap,
  ) async {
    await runBgeApp(
      platformBootstrap: bootstrap,
      hydratedStorageInitializer: (_) async {},
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  group('runBgeApp — root container sequencing', () {
    testWidgets('builds the root container exactly once, before the '
        'failure-prone platform initialize', (tester) async {
      final bootstrap = FakePlatformBootstrap();

      await boot(tester, bootstrap);

      expect(bootstrap.createRootContainerCallCount, 1);
      expect(
        bootstrap.calls.first,
        'createRootContainer',
        reason:
            'the root container must exist before anything that can '
            'fail, so device-global services are available on a failed '
            'boot (#69)',
      );
      expect(bootstrap.calls, contains('initialize'));
    });

    testWidgets('builds the root container before the error hooks are '
        'installed — #69 resolves the reporter from it', (tester) async {
      final beforeBoot = FlutterError.onError;
      bool? hooksAlreadyInstalledAtBuildTime;
      final bootstrap = FakePlatformBootstrap(
        onCreateRootContainer: () => hooksAlreadyInstalledAtBuildTime =
            !identical(FlutterError.onError, beforeBoot),
      );

      await boot(tester, bootstrap);

      expect(
        hooksAlreadyInstalledAtBuildTime,
        isFalse,
        reason: 'container construction precedes hook installation',
      );
      expect(
        identical(FlutterError.onError, beforeBoot),
        isFalse,
        reason:
            'the hooks are installed afterwards — boot still wires '
            'global error capture',
      );
    });

    testWidgets('hands the platform-built container to BgeApp and grants '
        'it ownership', (tester) async {
      final container = SpyRootContainer();
      final bootstrap = FakePlatformBootstrap(rootContainerOutcome: container);

      await boot(tester, bootstrap);

      final app = tester.widget<BgeApp>(find.byType(BgeApp));
      expect(app.rootContainer, same(container));
      expect(
        app.disposeRootContainerOnDispose,
        isTrue,
        reason:
            'runBgeApp has no teardown point of its own — the app widget '
            'owns the container lifecycle, mirroring '
            'closeBootstrapCubitOnDispose',
      );
    });

    testWidgets('disposes the root container when the app unmounts '
        '(hot-restart hygiene)', (tester) async {
      final container = SpyRootContainer();
      await boot(
        tester,
        FakePlatformBootstrap(rootContainerOutcome: container),
      );

      await unmount(tester);

      expect(container.disposed, isTrue);
    });
  });

  group('runBgeApp — createRootContainer failure (belt-and-braces guard)', () {
    testWidgets('boot proceeds on a functional empty fallback container '
        'and the hooks still install', (tester) async {
      final beforeBoot = FlutterError.onError;
      final bootstrap = FakePlatformBootstrap(
        rootContainerOutcome: StateError('root container build exploded'),
      );

      await boot(tester, bootstrap);

      expect(find.byType(BgeApp), findsOneWidget);
      expect(
        identical(FlutterError.onError, beforeBoot),
        isFalse,
        reason:
            'error capture must never be coupled to root-container '
            'success',
      );

      final fallback = tester.widget<BgeApp>(find.byType(BgeApp)).rootContainer;
      expect(fallback, isNotNull);
      expect(fallback!.isRegistered<_Marker>(), isFalse);
      final marker = _Marker();
      fallback.registerSingleton<_Marker>(marker);
      expect(
        fallback.get<_Marker>(),
        same(marker),
        reason: 'the fallback is a working container, not a null object',
      );
    });

    testWidgets('the failure lands as an error-level breadcrumb for '
        'feedback reports', (tester) async {
      final bootstrap = FakePlatformBootstrap(
        rootContainerOutcome: StateError('root container build exploded'),
      );

      await boot(tester, bootstrap);

      final crumbs = ShellObservability.breadcrumbs.snapshot().where(
        (c) =>
            c.loggerName == 'bge.shell.root_container' &&
            c.level == BgeLogLevel.error &&
            c.message.startsWith('Root container build failed'),
      );
      expect(crumbs, hasLength(1));
    });
  });
}
