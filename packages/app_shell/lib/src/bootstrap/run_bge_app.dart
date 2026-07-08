import 'dart:async';

import 'package:flutter/material.dart';

import '../observability/global_error_hooks.dart';
import '../observability/shell_observability.dart';
import '../widgets/bge_app.dart';
import 'app_bootstrap_cubit.dart';
import 'platform_bootstrap.dart';

/// Boots the application. This is the entire contract of each app's
/// `main.dart`: perform platform-specific setup, then hand a
/// [PlatformBootstrap] to this function.
///
/// Sequencing: observability (breadcrumb capture + last-error slot) →
/// binding init → global error hooks → construct [AppBootstrapCubit] →
/// start (not await) its bootstrap → `runApp`. Breadcrumbs attach first so
/// every later step — including bootstrap failures — is already captured
/// for feedback reports.
///
/// Error capture (issue #34) is [installGlobalErrorHooks]: the two
/// catch-all surfaces the Flutter team recommends, with **no custom
/// Zone** — per official guidance (3.3+), `PlatformDispatcher.onError`
/// supersedes `runZonedGuarded`. The pre-binding window here is a single
/// pure-Dart call ([ShellObservability.initialize]) and needs no zone.
///
/// `ErrorWidget.builder` (the in-build failure UI) is deliberately NOT
/// replaced in this bootstrap — that is presentation, split to #66 so the
/// capture wiring stays reviewable on its own. Until #66 lands, build
/// failures show Flutter's default error widget while still being fully
/// captured by the hooks above.
///
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
  UncaughtErrorReporter uncaughtErrorReporter =
      const NoopUncaughtErrorReporter(),
}) async {
  ShellObservability.initialize();
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalErrorHooks(reporter: uncaughtErrorReporter);

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
