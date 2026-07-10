import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

import '../../l10n/shell_localizations.dart';
import '../bootstrap/app_bootstrap_cubit.dart';
import '../observability/feedback_uncaught_error_reporter.dart';
import '../observability/shell_observability.dart';
import '../router/app_router.dart';
import 'crash_report_prompt.dart';

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
    this.feedbackReporter,
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

  /// The crash-draft reporter (#69), when `runBgeApp` created one. Drives
  /// the "ask each time" prompt overlay: a pending crash draft surfaces
  /// [CrashReportPrompt] above the router; approval submits via the
  /// reporter's service, decline clears both RAM slots (the draft and
  /// `ShellObservability.lastUncaughtError`). Null when the embedder
  /// supplied its own `UncaughtErrorReporter` (the override owns
  /// reporting; no prompt machinery is wired) — and in every pre-#69
  /// construction, which therefore behaves exactly as before.
  final FeedbackUncaughtErrorReporter? feedbackReporter;

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
    // order is NOT enforced. Assessed for #69 (per the deferral recorded
    // there): the container now holds BuildInfo (a value), a FeedbackSink,
    // and the FeedbackService — none is touched by the cubit's shutdown
    // and none needs a flush (sink writes are awaited at submit time), so
    // concurrent teardown remains safe. The enforcement (chain the
    // container's disposal after the cubit's close via whenComplete)
    // becomes necessary only when a genuinely cubit-touched service
    // lands; re-assess per registration.
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
        // The crash prompt overlays ABOVE the navigator (a crash draft
        // must surface regardless of the current route, including the
        // bootstrap-failure screen). The builder context sits below
        // Localizations/Theme, so the prompt self-localizes; it carries
        // its own Material since no Scaffold exists at this altitude.
        builder: (context, child) {
          final reporter = widget.feedbackReporter;
          final content = child ?? const SizedBox.shrink();
          if (reporter == null) return content;
          return ValueListenableBuilder<FeedbackReport?>(
            valueListenable: reporter.pendingCrashReport,
            builder: (context, draft, _) {
              return Stack(
                children: [
                  content,
                  if (draft != null) ...[
                    // Modal while a draft is pending: the barrier absorbs
                    // taps on the app behind and dims it, and
                    // BlockSemantics drops the underlying content from the
                    // semantics tree so assistive tech stays within the
                    // prompt. Non-dismissible — declining is an explicit
                    // choice via the prompt's Discard button, so an
                    // accidental scrim tap can't silently drop the report.
                    const BlockSemantics(
                      child: ModalBarrier(
                        dismissible: false,
                        color: Colors.black54,
                      ),
                    ),
                    SafeArea(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: CrashReportPrompt(
                            report: draft,
                            onSubmit: reporter.service.submit,
                            onDiscard: () {
                              // Decline (or dismiss an outcome): empty both
                              // RAM slots — the draft and the #34 last-error
                              // record ("clearUncaughtError on decline").
                              reporter.clearPendingCrashReport();
                              ShellObservability.clearUncaughtError();
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
        localizationsDelegates: [
          ...ShellLocalizations.localizationsDelegates,
          ...widget.additionalLocalizationsDelegates,
        ],
        supportedLocales: ShellLocalizations.supportedLocales,
      ),
    );
  }
}
