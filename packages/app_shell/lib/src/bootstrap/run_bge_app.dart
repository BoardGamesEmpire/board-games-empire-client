import 'dart:async';

import 'package:flutter/material.dart';
import 'package:observability/observability.dart';

import '../widgets/bge_app.dart';
import 'app_bootstrap_cubit.dart';
import 'platform_bootstrap.dart';
import '../observability/shell_observability.dart';

/// Hook for uncaught framework/platform errors (seam for the global error
/// wiring issue, #34, which will replace this with full zone + reporting
/// integration).
typedef UncaughtErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Boots the application. This is the entire contract of each app's
/// `main.dart`: perform platform-specific setup, then hand a
/// [PlatformBootstrap] to this function.
///
/// Sequencing: observability (breadcrumb capture) → binding init → error
/// hooks → construct [AppBootstrapCubit] → start (not await) its
/// bootstrap → `runApp`. Breadcrumbs attach first so every later step —
/// including bootstrap failures — is already captured for feedback
/// reports.
/// The splash route renders while bootstrap runs; hydrated-storage
/// initialization happens inside the cubit so its failures surface on the
/// retryable error screen instead of as a blank frame.
Future<void> runBgeApp({
  required PlatformBootstrap platformBootstrap,
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeMode themeMode = ThemeMode.system,
  List<LocalizationsDelegate<dynamic>> additionalLocalizationsDelegates =
      const [],
  UncaughtErrorHandler? onUncaughtError,
}) async {
  ShellObservability.initialize();
  final binding = WidgetsFlutterBinding.ensureInitialized();

  // Uncaught errors are always breadcrumbed so they appear in feedback
  // reports; the optional [onUncaughtError] hook is chained on top. Full
  // zone-based reporting is #34's scope and replaces neither of these.
  final uncaughtLogger = BgeLogger('bge.shell.uncaught');
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    previousOnError?.call(details);
    uncaughtLogger.error(
      'Uncaught framework error',
      error: details.exception,
      stackTrace: details.stack,
      context: {if (details.library != null) 'library': details.library},
    );
    onUncaughtError?.call(
      details.exception,
      details.stack ?? StackTrace.current,
    );
  };
  binding.platformDispatcher.onError = (error, stackTrace) {
    uncaughtLogger.error(
      'Uncaught platform error',
      error: error,
      stackTrace: stackTrace,
    );
    onUncaughtError?.call(error, stackTrace);
    return onUncaughtError != null;
  };

  final bootstrapCubit = AppBootstrapCubit(
    platformBootstrap: platformBootstrap,
  );
  unawaited(bootstrapCubit.initialize());

  runApp(
    BgeApp(
      bootstrapCubit: bootstrapCubit,
      // runBgeApp has no teardown point of its own, so the app widget
      // owns the cubit's lifecycle (relevant to hot restart and tests).
      closeBootstrapCubitOnDispose: true,
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      additionalLocalizationsDelegates: additionalLocalizationsDelegates,
    ),
  );
}
