import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/orchestration.dart';

import '../../l10n/shell_localizations.dart';
import '../bootstrap/app_bootstrap_cubit.dart';
import '../router/app_router.dart';

/// The shared application widget.
///
/// Seams left deliberately open for sibling P0 issues:
/// - [theme] / [darkTheme] / [themeMode] — theme + a11y baseline (#32);
/// - [additionalLocalizationsDelegates] — feature-package delegates
///   (e.g. auth's, wired by #33/#37) appended after the shell's own.
///
/// Deliberately free of process-global side effects: `ErrorWidget.builder`
/// (#66) and the uncaught-error hooks (#34) are installed by `runBgeApp`,
/// not here — flutter_test verifies per-test that widget builds leave
/// those globals untouched, and `BuildErrorView` self-localizes so no
/// captured context is needed (see `installBuildErrorView`).
class BgeApp extends StatefulWidget {
  const BgeApp({
    required this.bootstrapCubit,
    this.closeBootstrapCubitOnDispose = false,
    this.rootContainer,
    this.disposeRootContainerOnDispose = false,
    this.theme,
    this.darkTheme,
    this.themeMode = ThemeMode.system,
    this.additionalLocalizationsDelegates = const [],
    super.key,
  });

  final AppBootstrapCubit bootstrapCubit;

  /// Whether this widget owns [bootstrapCubit]'s lifecycle and closes it
  /// on unmount. `runBgeApp` (which creates the cubit and has no later
  /// teardown point) passes true; tests injecting their own cubits keep
  /// the default and close it themselves.
  final bool closeBootstrapCubitOnDispose;

  /// The app-scope, device-global root container (#72), built by the
  /// platform composition root via
  /// `PlatformBootstrap.createRootContainer` and handed in by
  /// `runBgeApp`.
  ///
  /// Held here for lifecycle ownership only — widget-tree exposure is
  /// deliberately deferred (#72 decision): nothing reads the container
  /// from `BuildContext` yet, and the first widget consumer adds a thin
  /// provider when it actually needs one.
  final DependencyContainer? rootContainer;

  /// Whether this widget owns [rootContainer]'s lifecycle and disposes it
  /// on unmount — the same ownership pattern as
  /// [closeBootstrapCubitOnDispose]. `runBgeApp` passes true; tests and
  /// embedders injecting their own container keep the default and dispose
  /// it themselves.
  final bool disposeRootContainerOnDispose;

  final ThemeData? theme;
  final ThemeData? darkTheme;
  final ThemeMode themeMode;
  final List<LocalizationsDelegate<dynamic>> additionalLocalizationsDelegates;

  @override
  State<BgeApp> createState() => _BgeAppState();
}

class _BgeAppState extends State<BgeApp> {
  late final BootstrapStreamListenable _refreshListenable;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _refreshListenable = BootstrapStreamListenable(
      widget.bootstrapCubit.stream,
    );
    _router = buildAppRouter(
      bootstrapCubit: widget.bootstrapCubit,
      refreshListenable: _refreshListenable,
    );
  }

  @override
  void dispose() {
    // Order matters: the router removes its listener from the listenable
    // during its own dispose, so the listenable must still be alive then.
    _router.dispose();
    _refreshListenable.dispose();
    if (widget.closeBootstrapCubitOnDispose) {
      unawaited(widget.bootstrapCubit.close());
    }
    // These teardowns run concurrently — dispose() cannot await, so the
    // order is NOT enforced. Safe while the root container is empty (#72
    // shell): there is no container-held service the cubit's shutdown
    // touches. Once #69 registers a cubit-touched service (e.g. a
    // feedback/analytics flush), it must sequence the container's disposal
    // after the cubit's close so the closing cubit cannot resolve an
    // already-disposed service.
    final rootContainer = widget.rootContainer;
    if (widget.disposeRootContainerOnDispose && rootContainer != null) {
      unawaited(rootContainer.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: widget.bootstrapCubit,
      child: MaterialApp.router(
        onGenerateTitle: (context) =>
            ShellLocalizations.of(context).shellAppTitle,
        theme: widget.theme,
        darkTheme: widget.darkTheme,
        themeMode: widget.themeMode,
        routerConfig: _router,
        localizationsDelegates: [
          ...ShellLocalizations.localizationsDelegates,
          ...widget.additionalLocalizationsDelegates,
        ],
        supportedLocales: ShellLocalizations.supportedLocales,
      ),
    );
  }
}
