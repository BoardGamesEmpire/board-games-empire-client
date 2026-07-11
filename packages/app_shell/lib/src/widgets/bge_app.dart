import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/shell_localizations.dart';
import '../bootstrap/app_bootstrap_cubit.dart';
import '../deep_links/deep_link_handler.dart';
import '../deep_links/pending_deep_link_holder.dart';
import '../i18n/active_locale.dart';
import '../observability/feedback_uncaught_error_reporter.dart';
import '../observability/shell_observability.dart';
import '../router/app_router.dart';
import 'crash_report_prompt.dart';

/// The shared application widget.
///
/// Theming (#32): the shell owns the theme defaults so per-app
/// `main.dart` stays thin — [theme]/[darkTheme] and the high-contrast
/// pair default to the corresponding [BgeTheme] factories when null, and
/// the OS "increase contrast" accessibility setting selects the
/// high-contrast variants automatically via `MaterialApp`. OS text
/// scaling is honored up to [BgeTextScale.maxScaleFactor] (WCAG 1.4.4:
/// 200%) via a `MediaQuery` clamp in the app builder. [themeMode] stays
/// [ThemeMode.system]; the user-facing selection + persistence is #78.
///
/// i18n (#33): the shell owns the localization composition. Its own
/// delegates ([ShellLocalizations.localizationsDelegates], which bundle
/// the three `Global*` delegates) come first;
/// [additionalLocalizationsDelegates] appends **single feature
/// delegates** (e.g. `AuthLocalizations.delegate`, wired by #37) — never
/// a feature's bundled `localizationsDelegates` list, which would
/// re-include the `Global*` delegates. [supportedLocales] stays
/// [ShellLocalizations.supportedLocales] with `en` first: Flutter's
/// default resolution (exact match → languageCode match → **first**
/// supported locale) then provides the `en` fallback with no custom
/// resolution callback; #78's user-selected override is the first thing
/// that would need one. [activeLocaleController], when supplied, is kept
/// in sync with the negotiated locale via [ActiveLocaleCapture] in the
/// app builder, so non-widget consumers (gateway hints, feedback
/// environment) read the locale the UI actually renders in.
///
/// Seams left deliberately open for sibling P0 issues:
/// - [additionalLocalizationsDelegates] — feature-package delegates
///   (auth's wired by #37) appended after the shell's own.
/// - [pendingDeepLinkHolder] (#10) — held here so #82 (consumption) and
///   #83 (auth-gate drain) can reach the pending slot from the widget
///   layer; nothing in the shell reads it yet.
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
    this.pendingDeepLinkHolder,
    this.deepLinkHandler,
    this.disposeDeepLinkHandlerOnDispose = false,
    this.activeLocaleController,
    this.disposeActiveLocaleControllerOnDispose = false,
    this.theme,
    this.darkTheme,
    this.highContrastTheme,
    this.highContrastDarkTheme,
    this.themeMode = ThemeMode.system,
    this.additionalLocalizationsDelegates = const [],
    super.key,
  });

  final AppBootstrapCubit bootstrapCubit;

  /// Key on the [BlockSemantics] that wraps the app content while a crash
  /// draft is pending, so tests can target it without colliding with the
  /// framework's own `BlockSemantics` widgets in the tree.
  static const Key contentSemanticsBlockerKey = Key(
    'bge_app.crash_prompt.content_semantics_blocker',
  );

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

  /// The single pending deep-link slot (#10), created by `runBgeApp` on
  /// every platform and fed by [deepLinkHandler] where one exists.
  ///
  /// Held here for future consumption — #82 drains it for navigation and
  /// server switching, #83's auth-gate both stashes redirect-bounced
  /// locations into it and drains it after sign-in. Nothing in the shell
  /// reads it yet.
  final PendingDeepLinkHolder? pendingDeepLinkHolder;

  /// The deep-link reception pipeline (#10), when the platform has an
  /// out-of-band channel (native). Null on web, where the browser URL is
  /// the link and `go_router` consumes it directly. Held for lifecycle
  /// ownership, like [rootContainer].
  final DeepLinkHandler? deepLinkHandler;

  /// Whether this widget owns [deepLinkHandler]'s lifecycle and disposes
  /// it on unmount — the same ownership pattern as
  /// [disposeRootContainerOnDispose]. `runBgeApp` passes true; tests
  /// injecting their own handler keep the default and dispose it
  /// themselves.
  final bool disposeDeepLinkHandlerOnDispose;

  /// The active-locale slot (#33), created and container-registered by
  /// `runBgeApp`. When non-null, [ActiveLocaleCapture] in the app builder
  /// mirrors the negotiated locale into it on every locale change; null
  /// (test/embedder default) wires no capture.
  final ActiveLocaleController? activeLocaleController;

  /// Whether this widget owns [activeLocaleController]'s lifecycle and
  /// disposes it on unmount — the same ownership pattern as
  /// [disposeRootContainerOnDispose]. `runBgeApp` passes true; tests
  /// injecting their own controller keep the default and dispose it
  /// themselves.
  final bool disposeActiveLocaleControllerOnDispose;

  /// The four theme slots (#32). Each defaults to its [BgeTheme] factory
  /// when null; explicit values are embedder/test overrides and win.
  final ThemeData? theme;
  final ThemeData? darkTheme;
  final ThemeData? highContrastTheme;
  final ThemeData? highContrastDarkTheme;

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
    // #10: cancel deep-link reception with the widget. The cancel itself
    // is issued synchronously inside dispose() (the await only covers
    // its completion), so links emitted after unmount are ignored.
    final deepLinkHandler = widget.deepLinkHandler;
    if (widget.disposeDeepLinkHandlerOnDispose && deepLinkHandler != null) {
      unawaited(deepLinkHandler.dispose());
    }
    // #33: the controller is a plain ValueNotifier — synchronous dispose,
    // no ordering concerns with the async teardowns around it.
    final activeLocaleController = widget.activeLocaleController;
    if (widget.disposeActiveLocaleControllerOnDispose &&
        activeLocaleController != null) {
      activeLocaleController.dispose();
    }
    // These teardowns run concurrently — dispose() cannot await, so the
    // order is NOT enforced. Assessed for #69 (per the deferral recorded
    // there): the container now holds BuildInfo (a value), a FeedbackSink,
    // the FeedbackService, and the ActiveLocaleReader (#33, a plain
    // value holder) — none is touched by the cubit's shutdown and none
    // needs a flush (sink writes are awaited at submit time), so
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
        theme: widget.theme ?? BgeTheme.light(),
        darkTheme: widget.darkTheme ?? BgeTheme.dark(),
        // Selected automatically when the OS "increase contrast"
        // accessibility setting is on (MediaQuery.highContrast) — no user
        // toggle needed (#32).
        highContrastTheme:
            widget.highContrastTheme ?? BgeTheme.highContrastLight(),
        highContrastDarkTheme:
            widget.highContrastDarkTheme ?? BgeTheme.highContrastDark(),
        themeMode: widget.themeMode,
        routerConfig: _router,
        // The crash prompt overlays ABOVE the navigator (a crash draft
        // must surface regardless of the current route, including the
        // bootstrap-failure screen). The builder context sits below
        // Localizations/Theme, so the prompt self-localizes; it carries
        // its own Material since no Scaffold exists at this altitude.
        builder: (context, child) {
          final content = child ?? const SizedBox.shrink();
          final reporter = widget.feedbackReporter;
          Widget body = reporter == null
              ? content
              : ValueListenableBuilder<FeedbackReport?>(
                  valueListenable: reporter.pendingCrashReport,
                  builder: (context, draft, _) {
                    final pending = draft != null;
                    return Stack(
                      children: [
                        // While a draft is pending, drop the underlying
                        // app from the semantics tree so assistive tech
                        // can't navigate background UI behind the modal
                        // prompt. BlockSemantics must wrap the CONTENT it
                        // blocks (it drops the semantics of widgets
                        // painted before it in the same container) —
                        // wrapping the barrier instead would leave the
                        // app fully reachable.
                        BlockSemantics(
                          key: BgeApp.contentSemanticsBlockerKey,
                          blocking: pending,
                          child: content,
                        ),
                        if (pending) ...[
                          // Plain tap-blocker: absorbs taps on the app
                          // behind and dims it. Non-dismissible —
                          // declining is an explicit choice via the
                          // prompt's Discard button, so an accidental
                          // scrim tap can't silently drop the report.
                          const ModalBarrier(
                            dismissible: false,
                            color: Colors.black54,
                          ),
                          // CrashReportPrompt applies its own SafeArea, so
                          // the overlay only positions it — no second
                          // SafeArea here (that would double-apply
                          // insets).
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: CrashReportPrompt(
                                report: draft,
                                onSubmit: reporter.service.submit,
                                onDiscard: () {
                                  // Decline (or dismiss an outcome): empty
                                  // both RAM slots — the draft and the #34
                                  // last-error record ("clearUncaughtError
                                  // on decline").
                                  reporter.clearPendingCrashReport();
                                  ShellObservability.clearUncaughtError();
                                },
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                );
          // #33: mirror the negotiated locale (this context sits below
          // the app's Localizations widget) into the app-scope slot so
          // non-widget consumers read what the UI actually renders in.
          final activeLocaleController = widget.activeLocaleController;
          if (activeLocaleController != null) {
            body = ActiveLocaleCapture(
              controller: activeLocaleController,
              child: body,
            );
          }
          // #32 / WCAG 1.4.4: honor OS text scaling up to 200%, clamped
          // app-wide (crash prompt included) so unbounded scale factors
          // can't break layouts while the full required range is
          // guaranteed.
          return MediaQuery.withClampedTextScaling(
            maxScaleFactor: BgeTextScale.maxScaleFactor,
            child: body,
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
