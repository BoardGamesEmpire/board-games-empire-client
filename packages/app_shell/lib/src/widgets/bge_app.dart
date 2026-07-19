import 'dart:async';

import 'package:auth/auth.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:server_onboarding/server_onboarding.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/shell_localizations.dart';
import '../bootstrap/app_bootstrap_cubit.dart';
import '../deep_links/deep_link_handler.dart';
import '../deep_links/pending_deep_link_holder.dart';
import '../i18n/active_locale.dart';
import '../observability/feedback_uncaught_error_reporter.dart';
import '../observability/shell_observability.dart';
import '../router/app_router.dart';
import '../screens/feedback_flow_screen.dart';
import '../screens/home_placeholder_screen.dart';
import '../screens/splash_screen.dart';
import 'crash_report_prompt.dart';
import 'feedback_review_screen.dart';
import 'router_back_interceptor.dart';

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
/// the three `Global*` delegates) come first; the feature single
/// delegates ([ServerOnboardingLocalizations.delegate] for #36,
/// [AuthLocalizations.delegate] for #37, [FeedbackLocalizations.delegate]
/// for #107) are appended next, then any
/// [additionalLocalizationsDelegates] — never a feature's bundled
/// `localizationsDelegates` list, which would re-include the `Global*`
/// delegates. [supportedLocales] stays [ShellLocalizations.supportedLocales]
/// with `en` first.
///
/// Auth wiring (#37): when the bootstrap cubit exposes an
/// [ActiveServerScope] with an active server, the router subtree is
/// wrapped in a [BlocProvider] of an [AuthBloc] bound to that server's
/// [AuthRepository], keyed on `ActiveServer.serverId` so a server switch
/// disposes the old bloc and builds a fresh one. A top-level
/// [BlocListener] translates the bloc's terminal auth states into
/// [AppBootstrapCubit.onAuthenticated] / [onSignedOut] — the presentation-
/// layer coordination that drives the router gate (blocs never depend on
/// blocs). The `/auth` route renders [AuthGate] and `/home` the temporary
/// [HomePlaceholderScreen]; both resolve the same provided bloc. When no
/// scope/active server is available (tests without a scope; web until
/// #96) the router renders its placeholders and no auth subtree is
/// mounted.
///
/// Crash reporting (#69, #76): when a [feedbackReporter] is supplied, the
/// app builder overlays the crash flow above the router's Navigator. A
/// pending draft first surfaces the compact [CrashReportPrompt] (#69);
/// tapping its "Review details" affordance seeds [_reviewPreview] (from
/// the draft plus the typed comment) and the overlay swaps to the
/// full-screen [FeedbackReviewScreen] (#76) in place — a route would
/// render *under* the crash barrier, so the review surface lives in the
/// same overlay. Both the prompt and the review surface submit through the
/// reporter's device-global service; discard/close clear the crash-draft
/// RAM slots.
///
/// Newest crash wins, even mid-review (#105): the review slot remembers
/// the draft **instance** it was opened for; when the pending draft
/// changes identity while the review surface is open, the slot is cleared
/// and the flow bounces back to the compact prompt — which reads the live
/// draft each build, so the newer crash is what the user sees. (Comparing
/// `correlationKey` would be equivalent today; `identical()` was chosen as
/// the smaller primitive. Revisit with `correlationKey` if the reporter
/// ever starts rebuilding equal drafts as new instances.)
///
/// System back (#106): while the crash flow is up, a
/// [RouterBackInterceptor] takes priority on the router's own
/// [BackButtonDispatcher] — the overlay has no route, so `PopScope`,
/// `BackButtonListener`, and a late `WidgetsBindingObserver` all fail here
/// (see the interceptor's doc for why). Back on the review surface bounces
/// to the compact prompt, matching its visible `BackButton`; back on the
/// prompt is intercepted-and-ignored the first time (arming a localized,
/// live-region dismiss hint) and discards the draft on a second press
/// within [crashPromptBackDismissWindow]. Any draft transition disarms the
/// hint. Known, accepted divergence: the host cannot see the review
/// surface's internal phase, so system back during its sending/terminal
/// phases also bounces to the prompt even though the visible `BackButton`
/// is disabled/hidden then — a re-send from the prompt is deduplicated
/// server-side by the report's `correlationKey`.
///
/// Seams left deliberately open for sibling issues:
/// - [pendingDeepLinkHolder] (#10) — held here so #82 (consumption) and
///   #83 (auth-gate drain) can reach the pending slot from the widget
///   layer; nothing in the shell reads it yet.
///
/// Deliberately free of process-global side effects: `ErrorWidget.builder`
/// (#66) and the uncaught-error hooks (#34) are installed by `runBgeApp`,
/// not here.
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

  /// How long a first intercepted system back on the compact crash prompt
  /// stays "armed" (#106): a second back within this window discards the
  /// draft; after it elapses the prompt returns to intercept-and-ignore.
  /// Two seconds is the Android "press back again to exit" convention.
  static const Duration crashPromptBackDismissWindow = Duration(seconds: 2);

  /// Whether this widget owns [bootstrapCubit]'s lifecycle and closes it
  /// on unmount. `runBgeApp` (which creates the cubit and has no later
  /// teardown point) passes true; tests injecting their own cubits keep
  /// the default and close it themselves.
  final bool closeBootstrapCubitOnDispose;

  /// The app-scope, device-global root container (#72), built by the
  /// platform composition root via
  /// `PlatformBootstrap.createRootContainer` and handed in by
  /// `runBgeApp`.
  final DependencyContainer? rootContainer;

  /// Whether this widget owns [rootContainer]'s lifecycle and disposes it
  /// on unmount.
  final bool disposeRootContainerOnDispose;

  /// The crash-draft reporter (#69), when `runBgeApp` created one.
  final FeedbackUncaughtErrorReporter? feedbackReporter;

  /// The single pending deep-link slot (#10), created by `runBgeApp` on
  /// every platform and fed by [deepLinkHandler] where one exists.
  final PendingDeepLinkHolder? pendingDeepLinkHolder;

  /// The deep-link reception pipeline (#10), when the platform has an
  /// out-of-band channel (native). Null on web.
  final DeepLinkHandler? deepLinkHandler;

  /// Whether this widget owns [deepLinkHandler]'s lifecycle and disposes
  /// it on unmount.
  final bool disposeDeepLinkHandlerOnDispose;

  /// The active-locale slot (#33), created and container-registered by
  /// `runBgeApp`.
  final ActiveLocaleController? activeLocaleController;

  /// Whether this widget owns [activeLocaleController]'s lifecycle and
  /// disposes it on unmount.
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

  /// The #76 review slot: non-null while the user is on the full review &
  /// redaction surface for the pending crash draft. Held at the widget
  /// layer (not on the reporter) because it is seeded from the typed
  /// comment and is purely presentational. The pending-crash listener
  /// ([_handlePendingCrashChanged]) clears it whenever the draft empties
  /// **or changes identity** (#105 — see [_reviewOpenedFor]), so a stale
  /// preview can never outlive, or shadow, its draft.
  final ValueNotifier<FeedbackReportPreview?> _reviewPreview =
      ValueNotifier<FeedbackReportPreview?>(null);

  /// The draft **instance** the open review surface was seeded from
  /// (#105). When [FeedbackUncaughtErrorReporter.pendingCrashReport] holds
  /// a different instance while [_reviewPreview] is set — a second crash
  /// overwrote the slot mid-review — the review is closed, bouncing back
  /// to the compact prompt, which reads the live draft each build
  /// (graceful newest-wins). Null whenever the review surface is closed.
  FeedbackReport? _reviewOpenedFor;

  /// Whether a first intercepted system back has "armed" prompt dismissal
  /// (#106). While true the compact prompt shows its localized dismiss
  /// hint and a second back discards the draft; [_promptDismissDisarmTimer]
  /// resets it after [BgeApp.crashPromptBackDismissWindow].
  final ValueNotifier<bool> _promptDismissArmed = ValueNotifier<bool>(false);
  Timer? _promptDismissDisarmTimer;

  @override
  void initState() {
    super.initState();
    _refreshListenable = BootstrapStreamListenable(
      widget.bootstrapCubit.stream,
    );
    _router = buildAppRouter(
      bootstrapCubit: widget.bootstrapCubit,
      refreshListenable: _refreshListenable,
      serverAddBuilder: _buildServerAddBuilder(),
      // Always supplied: the router is built in initState, before
      // bootstrap yields a scope, so gating these on availability *now*
      // would capture null forever. They resolve the scope at navigation
      // time instead — by then bootstrap has committed the active server
      // (a registered server routes to /auth only after that). When no
      // scope exists at all (web until #96), the builders fall back to the
      // placeholders, matching the pre-#37 behavior.
      authBuilder: _buildAuthRoute,
      homeBuilder: _buildHomeRoute,
      authScopeBuilder: _buildAuthScope,
      feedbackBuilder: _buildFeedbackRoute,
    );
    // #76/#105: keep the review slot honest whenever the crash draft
    // empties or changes identity.
    final reporter = widget.feedbackReporter;
    if (reporter != null) {
      reporter.pendingCrashReport.addListener(_handlePendingCrashChanged);
    }
  }

  /// Keeps the crash-flow presentation state consistent with the draft
  /// slot: any transition disarms the back-dismiss (#106 — the armed
  /// window belongs to the draft it was armed on); an emptied draft closes
  /// the review surface (#76); a draft that changed **identity** while the
  /// review surface is open closes it too, bouncing back to the compact
  /// prompt showing the newer crash (#105 newest-wins).
  void _handlePendingCrashChanged() {
    _disarmPromptDismiss();
    final draft = widget.feedbackReporter?.pendingCrashReport.value;
    if (draft == null) {
      _closeReview();
      return;
    }
    if (_reviewPreview.value != null && !identical(draft, _reviewOpenedFor)) {
      _closeReview();
    }
  }

  /// Seeds the #76 review surface from [draft] plus the comment typed on
  /// the compact prompt, remembering the draft identity for #105.
  void _openReview(FeedbackReport draft, String comment) {
    _reviewOpenedFor = draft;
    _reviewPreview.value = FeedbackReportPreview.fromReport(
      draft.withUserComment(comment),
    );
  }

  /// Closes the review surface (back to the compact prompt while a draft
  /// is still pending) and forgets the remembered draft identity.
  void _closeReview() {
    _reviewOpenedFor = null;
    _reviewPreview.value = null;
  }

  /// The single terminal exit of the crash flow: clears every
  /// presentation and RAM slot — review state, armed back-dismiss, the
  /// reporter's draft, and `ShellObservability`'s last-error record (#34
  /// contract).
  void _discardCrashDraft(FeedbackUncaughtErrorReporter reporter) {
    _disarmPromptDismiss();
    _closeReview();
    reporter.clearPendingCrashReport();
    ShellObservability.clearUncaughtError();
  }

  void _armPromptDismiss() {
    _promptDismissDisarmTimer?.cancel();
    _promptDismissArmed.value = true;
    _promptDismissDisarmTimer = Timer(
      BgeApp.crashPromptBackDismissWindow,
      _disarmPromptDismiss,
    );
  }

  void _disarmPromptDismiss() {
    _promptDismissDisarmTimer?.cancel();
    _promptDismissDisarmTimer = null;
    if (_promptDismissArmed.value) {
      _promptDismissArmed.value = false;
    }
  }

  /// Routes an intercepted system back press (#106). Always consumes —
  /// while the crash flow is up, back must never reach the router hidden
  /// under the barrier.
  Future<bool> _handleCrashBack(FeedbackUncaughtErrorReporter reporter) async {
    if (_reviewPreview.value != null) {
      // Review surface → compact prompt, matching its visible BackButton.
      _closeReview();
      return true;
    }
    if (_promptDismissArmed.value) {
      // Second back within the window → discard.
      _discardCrashDraft(reporter);
      return true;
    }
    // First back → intercept-and-ignore, arming the dismiss hint.
    _armPromptDismiss();
    return true;
  }

  /// Wraps the auth+home shell child with the active server's [AuthBloc]
  /// provider + gate listener (#37) — inside the router subtree, so the
  /// route widgets can resolve the bloc (a provider placed above
  /// `MaterialApp.router` is not reachable from go_router's Navigator).
  Widget _buildAuthScope(BuildContext context, Widget child) => _AuthScope(
    scope: widget.bootstrapCubit.activeServerScope,
    onAuthenticated: widget.bootstrapCubit.onAuthenticated,
    onSignedOut: widget.bootstrapCubit.onSignedOut,
    child: child,
  );

  /// Renders the auth route at navigation time. Falls back to the router's
  /// placeholder when no active server is resolvable (no scope, or none
  /// active yet) — the redirect only routes here once a server is active,
  /// so the fallback is transient/defensive.
  Widget? _buildAuthRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;
    return AuthGate(
      identity: active.identity,
      serverDisplayName: active.displayName,
      splash: const SplashScreen(),
    );
  }

  /// Renders the home route at navigation time. Null (→ placeholder) when
  /// no active server backs the auth bloc the home screen needs.
  Widget? _buildHomeRoute(BuildContext context) {
    if (widget.bootstrapCubit.activeServerScope?.active == null) return null;
    return const HomePlaceholderScreen();
  }

  /// The #107 user-initiated feedback wiring: resolves the device-global
  /// [FeedbackService] from the root container (#72) — decoupled from
  /// [BgeApp.feedbackReporter], which may legitimately be absent — and
  /// hosts the compose → review flow. Null (→ [NotYetAvailableScreen])
  /// when no container or no registered service exists (tests; a platform
  /// composition without feedback wiring), matching the
  /// [_buildServerAddBuilder] guard pattern.
  Widget? _buildFeedbackRoute(BuildContext context) {
    final container = widget.rootContainer;
    if (container == null || !container.isRegistered<FeedbackService>()) {
      return null;
    }
    return FeedbackFlowScreen(
      feedbackService: container.get<FeedbackService>(),
    );
  }

  /// The #36 server-add wiring.
  ServerAddScreenBuilder? _buildServerAddBuilder() {
    final container = widget.rootContainer;
    if (container == null || !container.isRegistered<WellKnownClient>()) {
      return null;
    }
    return (context) => BlocProvider<ServerOnboardingBloc>(
      create: (_) => ServerOnboardingBloc(
        wellKnownClient: container.get<WellKnownClient>(),
        versionNegotiator: container.get<VersionNegotiator>(),
        connectivityService: container.get<ConnectivityService>(),
        buildInfo: container.get<BuildInfo>(),
        orchestrator: widget.bootstrapCubit.orchestrator!,
      ),
      child: BlocListener<ServerOnboardingBloc, ServerOnboardingState>(
        listenWhen: (_, current) => current is ServerOnboardingSucceeded,
        listener: (_, _) => widget.bootstrapCubit.onServerRegistered(),
        child: const ServerAddScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _router.dispose();
    _refreshListenable.dispose();
    final reporter = widget.feedbackReporter;
    if (reporter != null) {
      reporter.pendingCrashReport.removeListener(_handlePendingCrashChanged);
    }
    _promptDismissDisarmTimer?.cancel();
    _promptDismissArmed.dispose();
    _reviewPreview.dispose();
    if (widget.closeBootstrapCubitOnDispose) {
      unawaited(widget.bootstrapCubit.close());
    }
    final deepLinkHandler = widget.deepLinkHandler;
    if (widget.disposeDeepLinkHandlerOnDispose && deepLinkHandler != null) {
      unawaited(deepLinkHandler.dispose());
    }
    final activeLocaleController = widget.activeLocaleController;
    if (widget.disposeActiveLocaleControllerOnDispose &&
        activeLocaleController != null) {
      activeLocaleController.dispose();
    }
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
      child: _buildMaterialApp(),
    );
  }

  Widget _buildMaterialApp() {
    return MaterialApp.router(
      onGenerateTitle: (context) =>
          ShellLocalizations.of(context).shellAppTitle,
      theme: widget.theme ?? BgeTheme.light(),
      darkTheme: widget.darkTheme ?? BgeTheme.dark(),
      highContrastTheme:
          widget.highContrastTheme ?? BgeTheme.highContrastLight(),
      highContrastDarkTheme:
          widget.highContrastDarkTheme ?? BgeTheme.highContrastDark(),
      themeMode: widget.themeMode,
      routerConfig: _router,
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        final reporter = widget.feedbackReporter;
        Widget body = reporter == null
            ? content
            : ValueListenableBuilder<FeedbackReport?>(
                valueListenable: reporter.pendingCrashReport,
                builder: (context, draft, _) {
                  return ValueListenableBuilder<FeedbackReportPreview?>(
                    valueListenable: _reviewPreview,
                    builder: (context, reviewPreview, _) {
                      return Stack(
                        children: [
                          BlockSemantics(
                            key: BgeApp.contentSemanticsBlockerKey,
                            blocking: draft != null,
                            child: content,
                          ),
                          if (draft != null) ...[
                            // #106: while the crash flow is up, take
                            // priority on the router's back dispatcher so
                            // system back never pops the hidden route
                            // under the barrier. Unmounts (and detaches)
                            // with the overlay.
                            RouterBackInterceptor(
                              dispatcher: _router.backButtonDispatcher,
                              onBack: () => _handleCrashBack(reporter),
                            ),
                            const ModalBarrier(
                              dismissible: false,
                              color: Colors.black54,
                            ),
                            // The builder slot sits ABOVE the router's
                            // Navigator, so the Navigator's Overlay is not
                            // an ancestor here — but both the compact
                            // prompt's comment field and the review
                            // surface's selectable trace require one
                            // (EditableText/SelectableText host their
                            // selection handles/toolbar in an Overlay).
                            // Without it, focusing throws, the hooks
                            // capture the throw, and the refilled draft
                            // slot re-summons the flow — making it
                            // undismissable.
                            if (reviewPreview == null)
                              // #69 compact "ask each time" prompt.
                              Overlay.wrap(
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: ValueListenableBuilder<bool>(
                                      valueListenable: _promptDismissArmed,
                                      builder: (context, dismissArmed, _) {
                                        return CrashReportPrompt(
                                          report: draft,
                                          // #106: after a first intercepted
                                          // back, surface the localized
                                          // live-region dismiss hint.
                                          showDismissHint: dismissArmed,
                                          onSubmit: reporter.service.submit,
                                          // #76: seed the review slot from
                                          // the draft plus the typed
                                          // comment; the overlay then swaps
                                          // to the full surface below.
                                          onReviewDetails: (comment) =>
                                              _openReview(draft, comment),
                                          onDiscard: () =>
                                              _discardCrashDraft(reporter),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              )
                            else
                              // #76 full review & redaction surface,
                              // filling the overlay above the barrier.
                              Positioned.fill(
                                child: Overlay.wrap(
                                  child: FeedbackReviewScreen(
                                    preview: reviewPreview,
                                    onSubmit: reporter.service.submit,
                                    // Back out of review → compact prompt.
                                    onCancel: _closeReview,
                                    // Dismiss after a terminal outcome →
                                    // clear every slot.
                                    onClose: () => _discardCrashDraft(reporter),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      );
                    },
                  );
                },
              );
        final activeLocaleController = widget.activeLocaleController;
        if (activeLocaleController != null) {
          body = ActiveLocaleCapture(
            controller: activeLocaleController,
            child: body,
          );
        }
        return MediaQuery.withClampedTextScaling(
          maxScaleFactor: BgeTextScale.maxScaleFactor,
          child: body,
        );
      },
      localizationsDelegates: [
        ...ShellLocalizations.localizationsDelegates,
        // #36 / #37 / #107: app_shell owns the feature route wiring, so it
        // also registers the feature single delegates — app entry points
        // stay thin.
        ServerOnboardingLocalizations.delegate,
        AuthLocalizations.delegate,
        FeedbackLocalizations.delegate,
        ...widget.additionalLocalizationsDelegates,
      ],
      supportedLocales: ShellLocalizations.supportedLocales,
    );
  }
}

/// Provides the active server's [AuthBloc] above the router and drives the
/// bootstrap gate from its state (#37).
///
/// Rebuilds on each [ActiveServer] emission; the [BlocProvider] is keyed
/// on `serverId` so a server switch tears down the old bloc and builds a
/// new one bound to the new server's repository. When [scope] is null (no
/// orchestration — web until #96) or has no active server, the child
/// renders without an auth bloc; the router's placeholder builders then
/// apply, and `onAuthenticated`/`onSignedOut` are simply never invoked.
class _AuthScope extends StatelessWidget {
  const _AuthScope({
    required this.scope,
    required this.onAuthenticated,
    required this.onSignedOut,
    required this.child,
  });

  final ActiveServerScope? scope;
  final VoidCallback onAuthenticated;
  final VoidCallback onSignedOut;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = this.scope;
    if (scope == null) return child;

    return StreamBuilder<ActiveServer?>(
      stream: scope.watchActive(),
      initialData: scope.active,
      builder: (context, snapshot) {
        final active = snapshot.data;
        if (active == null) return child;

        return BlocProvider<AuthBloc>(
          // Keyed on serverId: a switch disposes the old bloc (and its
          // repository subscription) and builds a fresh one. The startup
          // session check is dispatched on creation so every freshly-keyed
          // bloc restores its own server's session.
          key: ValueKey('auth_bloc_${active.serverId}'),
          create: (_) =>
              AuthBloc(authRepository: active.container.get<AuthRepository>())
                ..add(const AuthSessionCheckRequested()),
          child: BlocListener<AuthBloc, AuthBlocState>(
            listenWhen: (previous, current) =>
                current is AuthAuthenticated || current is AuthUnauthenticated,
            listener: (context, state) {
              if (state is AuthAuthenticated) {
                onAuthenticated();
              } else if (state is AuthUnauthenticated) {
                onSignedOut();
              }
            },
            child: child,
          ),
        );
      },
    );
  }
}
