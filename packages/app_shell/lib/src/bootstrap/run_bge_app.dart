import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter/material.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

import '../observability/global_error_hooks.dart';
import '../observability/shell_observability.dart';
import '../widgets/bge_app.dart';
import '../widgets/build_error_view.dart';
import 'app_bootstrap_cubit.dart';
import 'platform_bootstrap.dart';

/// Boots the application. This is the entire contract of each app's
/// `main.dart`: perform platform-specific setup, then hand a
/// [PlatformBootstrap] to this function.
///
/// Sequencing: observability (breadcrumb capture + last-error slot) →
/// binding init → **root container** → global error hooks → construct
/// [AppBootstrapCubit] → start (not await) its bootstrap → `runApp`.
/// Breadcrumbs attach first so every later step — including bootstrap
/// failures — is already captured for feedback reports.
///
/// The root container (issue #72) is the app-scope, device-global
/// [DependencyContainer], built by the platform composition root via
/// [PlatformBootstrap.createRootContainer]. It is acquired *before* the
/// error hooks and before the failure-prone platform [initialize], so
/// device-global services (client version #35, feedback #69) exist even
/// on a failed boot. Implementations must not throw (they register
/// degraded values instead); as a belt-and-braces guard, a throw here is
/// breadcrumbed at error level and boot proceeds on an empty fallback —
/// error capture is never coupled to root-container success. The app
/// widget owns the container's lifecycle
/// ([BgeApp.disposeRootContainerOnDispose]), since this function has no
/// teardown point of its own.
///
/// Error capture (issue #34) is [installGlobalErrorHooks]: the two
/// catch-all surfaces the Flutter team recommends, with **no custom
/// Zone** — per official guidance (3.3+), `PlatformDispatcher.onError`
/// supersedes `runZonedGuarded`. The pre-binding window here is a single
/// pure-Dart call ([ShellObservability.initialize]) and needs no zone.
///
/// Error presentation (issue #66) is [installBuildErrorView], replacing
/// the default in-build failure UI with a localized, accessible view.
/// Capture (#34) and presentation (#66) are deliberately separate units;
/// both are installed here because they mutate process globals, which
/// belongs in bootstrap, not in widget builds (see [installBuildErrorView]
/// for the flutter_test invariant that forbids the in-widget placement).
///
/// The splash route renders while bootstrap runs; hydrated-storage
/// initialization happens inside the cubit so its failures surface on the
/// retryable error screen instead of as a blank frame.
/// [hydratedStorageInitializer] is forwarded to the cubit — the same
/// injectable seam [AppBootstrapCubit] already exposes, here so shell
/// tests can drive the real `runBgeApp` without touching real Hive IO;
/// production callers leave it null for the cubit's real default.
Future<void> runBgeApp({
  required PlatformBootstrap platformBootstrap,
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeMode themeMode = ThemeMode.system,
  List<LocalizationsDelegate<dynamic>> additionalLocalizationsDelegates =
      const [],
  UncaughtErrorReporter uncaughtErrorReporter =
      const NoopUncaughtErrorReporter(),
  HydratedStorageInitializer? hydratedStorageInitializer,
}) async {
  ShellObservability.initialize();
  WidgetsFlutterBinding.ensureInitialized();

  // Root container before the hooks: #69 resolves the crash reporter from
  // it, and a container that only exists after a successful bootstrap
  // could never stamp a failed-boot feedback report.
  //
  // This is the one window not covered by the global error hooks (they
  // install just below) and there is deliberately no Zone — a tradeoff of
  // the container-before-hooks ordering. The awaited call surfaces
  // synchronous throws and the awaited future's rejection into the catch
  // below; the residual gap is a *detached* async error during the build,
  // which the createRootContainer contract forbids (its work must be
  // synchronous or fully awaited).
  DependencyContainer rootContainer;
  try {
    rootContainer = await platformBootstrap.createRootContainer();
  } on Object catch (error, stackTrace) {
    // Contract violation — implementations must not throw. Breadcrumb it
    // (observability is already live) and boot on a working empty
    // container: error capture must never be coupled to root-container
    // success. The fallback is empty, so failed-boot consumers of the
    // container resolve-or-default (see createRootContainer's contract).
    BgeLogger('bge.shell.root_container').error(
      'Root container build failed; booting with an empty fallback '
      'container',
      error: error,
      stackTrace: stackTrace,
    );
    rootContainer = DependencyContainerImpl();
  }

  installGlobalErrorHooks(reporter: uncaughtErrorReporter);
  installBuildErrorView();

  final bootstrapCubit = AppBootstrapCubit(
    platformBootstrap: platformBootstrap,
    hydratedStorageInitializer: hydratedStorageInitializer,
  );
  unawaited(bootstrapCubit.initialize());

  runApp(
    BgeApp(
      bootstrapCubit: bootstrapCubit,
      // runBgeApp has no teardown point of its own, so the app widget
      // owns the cubit's and the root container's lifecycles (relevant
      // to hot restart and tests).
      closeBootstrapCubitOnDispose: true,
      rootContainer: rootContainer,
      disposeRootContainerOnDispose: true,
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      additionalLocalizationsDelegates: additionalLocalizationsDelegates,
    ),
  );
}
