import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/bge_app.dart';
import 'app_bootstrap_cubit.dart';
import 'platform_bootstrap.dart';

/// Hook for uncaught framework/platform errors (seam for the global error
/// wiring issue, #34, which will replace this with full zone + reporting
/// integration).
typedef UncaughtErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Boots the application. This is the entire contract of each app's
/// `main.dart`: perform platform-specific setup, then hand a
/// [PlatformBootstrap] to this function.
///
/// Sequencing: binding init → error hooks → construct
/// [AppBootstrapCubit] → start (not await) its bootstrap → `runApp`.
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
  final binding = WidgetsFlutterBinding.ensureInitialized();

  if (onUncaughtError != null) {
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      previousOnError?.call(details);
      onUncaughtError(details.exception, details.stack ?? StackTrace.current);
    };
    binding.platformDispatcher.onError = (error, stackTrace) {
      onUncaughtError(error, stackTrace);
      return true;
    };
  }

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
