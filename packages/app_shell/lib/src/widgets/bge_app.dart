import 'dart:async';

import 'package:auth/auth.dart';
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
import '../screens/home_placeholder_screen.dart';
import '../screens/splash_screen.dart';
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
/// the three `Global*` delegates) come first; the feature single
/// delegates ([ServerOnboardingLocalizations.delegate] for #36,
/// [AuthLocalizations.delegate] for #37) are appended next, then any
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
    );
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
                  final pending = draft != null;
                  return Stack(
                    children: [
                      BlockSemantics(
                        key: BgeApp.contentSemanticsBlockerKey,
                        blocking: pending,
                        child: content,
                      ),
                      if (pending) ...[
                        const ModalBarrier(
                          dismissible: false,
                          color: Colors.black54,
                        ),
                        // The builder slot sits ABOVE the router's
                        // Navigator, so the Navigator's Overlay is not an
                        // ancestor here — but the prompt's comment
                        // TextField requires one (EditableText hosts its
                        // selection handles/toolbar in an Overlay).
                        // Without this, focusing the field throws, the
                        // hooks capture the throw, and the refilled draft
                        // slot re-summons the prompt — making it
                        // undismissable.
                        Overlay.wrap(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: CrashReportPrompt(
                                report: draft,
                                onSubmit: reporter.service.submit,
                                onDiscard: () {
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
        // #36 / #37: app_shell owns the feature route wiring, so it also
        // registers the feature single delegates — app entry points stay
        // thin.
        ServerOnboardingLocalizations.delegate,
        AuthLocalizations.delegate,
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
