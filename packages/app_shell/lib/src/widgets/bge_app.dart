import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/shell_localizations.dart';
import '../bootstrap/app_bootstrap_cubit.dart';
import '../router/app_router.dart';

/// The shared application widget.
///
/// Seams left deliberately open for sibling P0 issues:
/// - [theme] / [darkTheme] / [themeMode] — theme + a11y baseline (#32);
/// - [additionalLocalizationsDelegates] — feature-package delegates
///   (e.g. auth's, wired by #33/#37) appended after the shell's own.
class BgeApp extends StatefulWidget {
  const BgeApp({
    required this.bootstrapCubit,
    this.closeBootstrapCubitOnDispose = false,
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
