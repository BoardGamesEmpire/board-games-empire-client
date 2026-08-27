import 'dart:async';

import 'package:auth/auth.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:server_onboarding/server_onboarding.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:ui/ui.dart' show UnverifiedSessionBanner;

import '../../l10n/shell_localizations.dart';
import '../bootstrap/app_bootstrap_cubit.dart';
import '../bootstrap/app_bootstrap_state.dart';
import '../deep_links/deep_link_handler.dart';
import '../deep_links/pending_deep_link_holder.dart';
import '../i18n/active_locale.dart';
import '../observability/feedback_uncaught_error_reporter.dart';
import '../observability/shell_observability.dart';
import '../router/app_router.dart';
import '../screens/feedback_flow_screen.dart';
import '../screens/home_menu_entry.dart';
import '../screens/home_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/splash_screen.dart';
import '../settings/locale_cubit.dart';
import '../settings/settings_sections_builder.dart';
import '../settings/theme_mode_cubit.dart';
import 'crash_report_prompt.dart';
import 'feedback_review_screen.dart';
import 'router_back_interceptor.dart';
import 'detached_rehydrate.dart';
import 'session_rehydrate_trigger.dart';

/// The shared application widget.
///
/// Theming (#32): the shell owns the theme defaults so per-app
/// `main.dart` stays thin — [theme]/[darkTheme] and the high-contrast
/// pair default to the corresponding [BgeTheme] factories when null, and
/// the OS "increase contrast" accessibility setting selects the
/// high-contrast variants automatically via `MaterialApp`. OS text
/// scaling is honored up to [BgeTextScale.maxScaleFactor] (WCAG 1.4.4:
/// 200%) via a `MediaQuery` clamp in the app builder. The persisted user
/// selection drives `MaterialApp`'s `themeMode`/`locale` via app-level
/// [HydratedCubit]s created once hydrated storage is ready (#120);
/// [BgeApp.themeMode]/[BgeApp.locale] are the pre-storage-ready fallback
/// and a test/embedder seam.
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
/// blocs). The `/auth` route renders [AuthGate] and `/home` the
/// navigation-drawer menu ([HomeScreen], #129); both resolve the same
/// provided bloc. When no
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
/// `clientRequestId` would be equivalent today; `identical()` was chosen as
/// the smaller primitive. Revisit with `clientRequestId` if the reporter
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
/// server-side by the report's `clientRequestId`.
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
    this.locale,
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

  /// Explicit `MaterialApp.locale` override (test/embedder seam). Null
  /// follows system resolution. In production the persisted [LocaleCubit]
  /// override wins once available (#120); this is the pre-storage-ready
  /// fallback.
  final Locale? locale;
  final List<LocalizationsDelegate<dynamic>> additionalLocalizationsDelegates;

  @override
  State<BgeApp> createState() => _BgeAppState();
}

class _BgeAppState extends State<BgeApp> {
  late final BootstrapStreamListenable _refreshListenable;
  late final GoRouter _router;

  /// Diagnostics for route builders that degrade to a placeholder because
  /// the composition cannot back them (#189).
  static final BgeLogger _log = BgeLogger('bge.shell.router');

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

  /// App-level, persisted theme-mode + locale controllers (#120).
  ///
  /// Created lazily on the first storage-ready bootstrap state — never
  /// eagerly. They are [HydratedCubit]s, and `HydratedBloc.storage` is
  /// initialized inside `AppBootstrapCubit`'s bootstrap *before* it emits
  /// any post-init state (see [_isStorageReady]); constructing them before
  /// then would call `hydrate()` with no storage and throw
  /// `StorageNotFound`, crashing before the first frame — the exact
  /// failure the deferred storage init exists to route to the retryable
  /// error screen. App-level (not per-server): a sign-out must not tear
  /// them down, so they live for the app's lifetime and are closed in
  /// [dispose]. Null until created, or if storage was unavailable, in
  /// which case theme/locale fall back to
  /// [BgeApp.themeMode]/[BgeApp.locale].
  ThemeModeCubit? _themeModeCubit;
  LocaleCubit? _localeCubit;
  bool _settingsControllersCreated = false;
  StreamSubscription<AppBootstrapState>? _settingsControllerSub;

  /// Rebuild [MaterialApp.router] when a settings controller emits. Kept
  /// as plain stream subscriptions (rather than wrapping the app in a
  /// `BlocBuilder`) so the widget *structure* under [build] never changes
  /// shape when the controllers appear: a `BlocBuilder` wrapper would only
  /// exist once the cubits do, and swapping it in would remount the whole
  /// `MaterialApp.router` subtree — discarding in-flight Navigator/overlay
  /// state (e.g. a half-typed crash-prompt comment). `setState` on the
  /// same-shaped tree updates `themeMode`/`locale` in place instead.
  StreamSubscription<ThemeMode>? _themeModeSub;
  StreamSubscription<Locale?>? _localeSub;

  @override
  void initState() {
    super.initState();
    _refreshListenable = BootstrapStreamListenable(
      widget.bootstrapCubit.stream,
    );
    _router = buildAppRouter(
      bootstrapCubit: widget.bootstrapCubit,
      refreshListenable: _refreshListenable,
      // Always supplied: the router is built in initState, before
      // bootstrap yields an orchestrator or a scope, so gating these on
      // availability *now* would capture null forever. They resolve at
      // navigation time instead — by then bootstrap has committed the
      // active server (a registered server routes to /auth only after
      // that) and published the orchestrator. When the backing
      // composition is absent altogether (a partial or empty root
      // container; a platform with no orchestrator), the builders fall
      // back to the placeholders, matching the pre-#37 behavior.
      serverAddBuilder: _buildServerAddRoute,
      authBuilder: _buildAuthRoute,
      homeBuilder: _buildHomeRoute,
      authScopeBuilder: _buildAuthScope,
      feedbackBuilder: _buildFeedbackRoute,
      settingsBuilder: _buildSettingsRoute,
      householdListBuilder: _buildHouseholdListRoute,
      householdDetailBuilder: _buildHouseholdDetailRoute,
      createHouseholdBuilder: _buildCreateHouseholdRoute,
    );
    // #76/#105: keep the review slot honest whenever the crash draft
    // empties or changes identity.
    final reporter = widget.feedbackReporter;
    if (reporter != null) {
      reporter.pendingCrashReport.addListener(_handlePendingCrashChanged);
    }
    // #120: create the persisted theme-mode + locale controllers as soon
    // as hydrated storage is ready (the first storage-ready bootstrap
    // state), then keep them for the app's lifetime. See the field docs
    // for why they cannot be constructed eagerly here. If we are already at
    // a storage-ready state we try synchronously; otherwise (or if that
    // attempt fails) we listen and retry on later storage-ready states,
    // cancelling only once creation succeeds.
    if (_isStorageReady(widget.bootstrapCubit.state)) {
      _createSettingsControllers();
    }
    if (!_settingsControllersCreated) {
      _settingsControllerSub = widget.bootstrapCubit.stream.listen(
        _onBootstrapStateForSettings,
      );
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
    connectivity: _rootConnectivity(),
    child: child,
  );

  /// Resolves a device-global service from [BgeApp.rootContainer], or null
  /// when there is no container or [T] is not registered in it.
  ///
  /// The one place the check-then-resolve pair lives. Route builders that
  /// need several services get a nullable local per service, so a missing
  /// one is a `null` the type system carries into the constructor call
  /// rather than a check that can be forgotten (#189: the `/server-add`
  /// guard verified one of the five collaborators it went on to resolve).
  ///
  /// Never from a per-server container, whose contract forbids
  /// parent-scope lookup (#38) — these are device-global concerns
  /// registered once at the root.
  T? _rootService<T extends Object>() {
    final container = widget.rootContainer;
    if (container == null || !container.isRegistered<T>()) return null;
    return container.get<T>();
  }

  /// Root-scoped [ConnectivityService] for the auth bloc's offline fast
  /// path and reconnect revalidation (#98). Null (no container, or a
  /// composition without connectivity wiring — tests, or a platform that
  /// never registered it) degrades the bloc gracefully: no fast path, no
  /// automatic revalidation, indeterminate fallback intact.
  ConnectivityService? _rootConnectivity() =>
      _rootService<ConnectivityService>();

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

  /// Renders the home route at navigation time — the navigation-drawer
  /// menu (#129). Null (→ [NotYetAvailableScreen]) when no active server
  /// backs the auth bloc the sign-out entry needs. Entry labels are
  /// resolved here from each feature's localizations; each entry's action
  /// runs against the context [HomeScreen] hands back (its State context,
  /// under the auth scope + router), so `context.push` / `context.read`
  /// resolve.
  Widget? _buildHomeRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final authL10n = AuthLocalizations.of(context);
    final feedbackL10n = FeedbackLocalizations.of(context);
    final householdL10n = HouseholdLocalizations.of(context);
    final shellL10n = ShellLocalizations.of(context);

    // Only surface households where the household scope is actually
    // installed — the same guard _buildHouseholdListRoute applies.
    // Otherwise the entry would dead-end on the (back-button-less)
    // NotYetAvailableScreen. Post-#135 the household repository lives in
    // the per-USER session scope, so on native this is true exactly while
    // a user session is active — which home's own auth gating already
    // implies — and false on web until its user tier lands (#137/#125).
    //
    // The repository ALONE (#269 D4): this entry opens the list, which
    // renders from the local cache. A missing HouseholdRemoteDataSource
    // costs the list its create affordance, not its existence — so gating
    // the entry on it, as the create entry this replaces had to, would
    // hide a screen that works.
    final container = active.container;
    final canReadHouseholds = container.isRegistered<HouseholdRepository>();

    return HomeScreen(
      activeServerName: active.displayName,
      entries: [
        if (canReadHouseholds)
          HomeMenuEntry(
            id: 'households',
            icon: Icons.groups_outlined,
            label: householdL10n.householdListTitle,
            onSelected: (ctx) => ctx.push(AppRoutes.household),
          ),
        HomeMenuEntry(
          id: 'send_feedback',
          icon: Icons.feedback_outlined,
          label: feedbackL10n.feedbackComposeTitle,
          onSelected: (ctx) => ctx.push(AppRoutes.feedback),
        ),
        HomeMenuEntry(
          id: 'settings',
          icon: Icons.settings_outlined,
          label: shellL10n.settingsTitle,
          onSelected: (ctx) => ctx.push(AppRoutes.settings),
        ),
        HomeMenuEntry(
          id: 'sign_out',
          icon: Icons.logout,
          label: authL10n.authSignOutButton,
          isDestructive: true,
          onSelected: (ctx) =>
              ctx.read<AuthBloc>().add(const AuthSignOutRequested()),
        ),
      ],
    );
  }

  /// The #300 retry, for both household screens: the session-scoped
  /// [HouseholdRefresher] the hydrate installer registers, or null where
  /// this composition runs no drain (#137, and any container without a
  /// household client).
  ///
  /// Optional for the same reason `onCreate` is: a screen that cannot
  /// refresh should say the list may be stale and offer nothing to press,
  /// rather than a button that does nothing.
  ///
  /// Not the [SessionRehydrator] the shell drives on a connectivity edge:
  /// that seam skips an entry whose pass is already running (#302 D4),
  /// which is right for a trigger nobody pressed and wrong for a button
  /// someone is waiting on. Both end at the same pass and the same status.
  ///
  /// Resolved per route build, like everything else here — a callback
  /// captured across a session change would hold a disposed scope's
  /// hydrator.
  Future<void> Function()? _householdRetry(DependencyContainer container) =>
      container.isRegistered<HouseholdRefresher>()
      ? container.get<HouseholdRefresher>().refresh
      : null;

  /// The #300 re-hydrate-on-entry trigger (D1, D13): the session's
  /// [SessionRehydrator], or null where this composition has no re-hydrate
  /// seam at all (#137).
  ///
  /// **The opposite call from [_householdRetry], on purpose.** A press gets
  /// the household's own pass, because the rehydrator drops a pass while
  /// one is running (#302 D4) and "I pressed it and nothing happened" is
  /// the one outcome a manual affordance cannot afford. An entry gets the
  /// rehydrator, because that skip is exactly right for something nobody
  /// pressed, and because the staleness window that decides whether to do
  /// any work lives in the registry's `isStale` (#300 D8) rather than being
  /// re-answered here.
  ///
  /// Once #121 registers the sync-queue drain, entering the household list
  /// will drive that too. That is a trigger behaving like a trigger; the
  /// button deliberately does not (#300 D13).
  VoidCallback? _householdEntryRefresh(DependencyContainer container) {
    if (!container.isRegistered<SessionRehydrator>()) return null;
    final rehydrator = container.get<SessionRehydrator>();

    // Resolved per route build, like the retry above, and the pass itself
    // goes through the shell's shared guard. That guard is what makes this
    // safe to call from a `BlocProvider.create` (#300 D14) — it runs during
    // a build, so nothing here may throw into that frame, and nothing may
    // emit synchronously either. Neither does: the drain's first status
    // update is delivered by a broadcast controller.
    return () => startDetachedRehydrate(
      trigger: 'household_entry',
      resolve: () => rehydrator,
    );
  }

  /// The #269 household-list wiring: resolves the [HouseholdRepository]
  /// (per-user session scope, #135) from the *active server's* scoped
  /// container, plus the optional [HouseholdHydrationStatus] the hydrate
  /// installer publishes (#267/#269 D1). Null (→ [NotYetAvailableScreen])
  /// when no active server is resolvable or its container carries no
  /// repository (tests without a scope; no active user session; web until
  /// its user tier lands, #137).
  ///
  /// Two things are deliberately *optional* here where the create route
  /// requires them:
  ///
  /// - the **hydration status** is absent on any composition that runs no
  ///   drain, and the screen reads absent as settled rather than as
  ///   forever-loading;
  /// - the **remote data source** decides only whether `onCreate` is
  ///   offered. A container without one still gets a working list (#269
  ///   D4), which is the whole reason this route's gate is narrower than
  ///   the create route's.
  ///
  /// Captured-instance lifetime is the create route's, for the create
  /// route's reasons: a session ending disposes the repository and the auth
  /// redirect pops this route. A `watch*` subscription racing that window
  /// **closes** (`WatchDisposal` closes vended streams rather than erroring
  /// them), which the list bloc reads as "no more answers" — freezing rows
  /// it already has, or surfacing its error state when it never got any.
  Widget? _buildHouseholdListRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    if (!container.isRegistered<HouseholdRepository>()) return null;

    final hydration = container.isRegistered<HouseholdHydrationStatus>()
        ? container.get<HouseholdHydrationStatus>().watch()
        : null;

    return HouseholdListScreen(
      repository: container.get<HouseholdRepository>(),
      hydration: hydration,
      onRetry: _householdRetry(container),
      onEnter: _householdEntryRefresh(container),
      onCreate: container.isRegistered<HouseholdRemoteDataSource>()
          ? (ctx) => ctx.push(AppRoutes.householdCreate)
          : null,
      // #270: rows became controls when there was somewhere for them to
      // go. Unconditional, unlike `onCreate` — the detail route's guard is
      // this route's own, so any container that can render the list can
      // render a row's destination.
      onOpen: (ctx, householdId) =>
          ctx.push(AppRoutes.householdDetailOf(householdId)),
    );
  }

  /// The #270 household-detail wiring. Resolves the same user-session
  /// [HouseholdRepository] and optional [HouseholdHydrationStatus] as
  /// [_buildHouseholdListRoute], and guards on the repository alone for
  /// the same reason (#269 D4): the detail screen reads the local cache
  /// and never calls the server.
  ///
  /// [householdId] arrives from the path, unvalidated. Nothing checks it
  /// here — an unreadable id is exactly what the screen's not-found state
  /// is for, and the repository's membership gate makes "malformed",
  /// "not yours" and "deleted" one answer anyway.
  ///
  /// Captured-instance lifetime is the list route's, and so is the
  /// behaviour when a session ends under it: the scope pop disposes the
  /// repository, the vended `watch*` streams **close** rather than error,
  /// and the detail bloc freezes what it had while the auth redirect pops
  /// the route.
  Widget? _buildHouseholdDetailRoute(BuildContext context, String householdId) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    if (!container.isRegistered<HouseholdRepository>()) return null;

    final hydration = container.isRegistered<HouseholdHydrationStatus>()
        ? container.get<HouseholdHydrationStatus>().watch()
        : null;

    return HouseholdDetailScreen(
      householdId: householdId,
      repository: container.get<HouseholdRepository>(),
      hydration: hydration,
      onRetry: _householdRetry(container),
      // Not a pop: this route can be entered cold (a restored route, and
      // the invite deep link later), where there is nothing beneath it.
      onBack: (ctx) => ctx.go(AppRoutes.household),
    );
  }

  /// The #129 create-household wiring: resolves the [HouseholdRepository]
  /// (per-user session scope, #135) and [HouseholdRemoteDataSource]
  /// (per-server scope) from the *active server's* scoped container — not
  /// [BgeApp.rootContainer]. Null (→ [NotYetAvailableScreen]) when no
  /// active server is resolvable or its container lacks either dependency
  /// (tests without a scope; no active user session; web until its user
  /// tier lands, #137).
  ///
  /// ## Captured-repository lifetime (#135)
  ///
  /// The repository instance is captured at route build. If the session
  /// ends while this screen is pushed (sign-out from another surface,
  /// token expiry), the scope pop disposes that instance and the auth
  /// redirect pops this route; a submit racing that window hits the
  /// repository's disposed guard as a StateError, which
  /// `CreateHouseholdBloc` already contains — every repository call runs
  /// under `on Object catch`, surfacing as a logged local-create failure
  /// (or a queued-pending success post-server-create), never an unhandled
  /// error. Accepted rather than resolving per-action: the outcome is
  /// identical (a post-pop resolution would throw not-registered into the
  /// same handlers) for measurably more machinery.
  Widget? _buildCreateHouseholdRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    if (!container.isRegistered<HouseholdRepository>() ||
        !container.isRegistered<HouseholdRemoteDataSource>()) {
      return null;
    }

    return CreateHouseholdScreen(
      repository: container.get<HouseholdRepository>(),
      remote: container.get<HouseholdRemoteDataSource>(),
      // #271: the new household's own screen takes the place of the spent
      // form, so back can never land on it again (#162).
      //
      // `pushReplacement`, not `replace` (#271 D1): both drop the top-most
      // page, but `replace` reuses its page key and runs no animation —
      // that is for swapping a route for a variant of itself, not for
      // substituting an unrelated screen.
      //
      // On the drawer path (list → FAB → create) the list route is still
      // beneath, so back pops onto it. On direct entry the stack is one deep
      // and go_router degrades this to a plain `go`, making the detail screen
      // the base location; its own back affordance
      // (`ctx.go(AppRoutes.household)`, above) is what reaches the list
      // there. A system back from that state leaves the app, as it already
      // does for a cold-entered detail route (#271 D3).
      onCreated: (ctx, householdId) {
        // #300 D3/D9: a create makes the local set stale by definition, so
        // the next entry to the list re-hydrates rather than waiting out
        // the remaining window. Cleared here, before the navigation, and
        // not inside the household feature — the invalidation belongs to
        // *mutation*, and this is where mutations are already wired, which
        // is what gives #122's membership mutations the same hook.
        //
        // Absent on a composition that runs no drain (#137): nothing to
        // invalidate, and a create must not care.
        if (container.isRegistered<HouseholdHydrationStatus>()) {
          container.get<HouseholdHydrationStatus>().markStale();
        }
        ctx.pushReplacement(AppRoutes.householdDetailOf(householdId));
      },
    );
  }

  /// The #107 user-initiated feedback wiring: resolves the device-global
  /// [FeedbackService] from the root container (#72) — decoupled from
  /// [BgeApp.feedbackReporter], which may legitimately be absent — and
  /// hosts the compose → review flow. Null (→ [NotYetAvailableScreen])
  /// when no container or no registered service exists (tests; a platform
  /// composition without feedback wiring).
  ///
  /// Not logged, unlike [_buildServerAddRoute]: this route is *pushed*
  /// from the home menu rather than pinned by a bootstrap redirect, so the
  /// fallback is a screen the user chose to open and the app is still
  /// working. That said, [NotYetAvailableScreen] carries no app bar and so
  /// no back button, which on desktop (no system back gesture, no hardware
  /// key) leaves no visible exit — tracked separately rather than papered
  /// over with a log here.
  Widget? _buildFeedbackRoute(BuildContext context) {
    final feedbackService = _rootService<FeedbackService>();
    if (feedbackService == null) return null;
    return FeedbackFlowScreen(feedbackService: feedbackService);
  }

  /// The #36 server-add wiring, resolved at navigation time (#189).
  ///
  /// Resolution has to happen at navigation time because the
  /// [ServerOrchestrator] does not exist when the router is built —
  /// `AppBootstrapCubit` only publishes it once bootstrap has succeeded,
  /// so an availability check in `initState` would capture null forever
  /// (the same reason the auth/home builders resolve late).
  ///
  /// Every collaborator is a nullable local, and the guard is one
  /// all-or-nothing check over the whole set. That is deliberate: adding a
  /// required dependency to [ServerOnboardingBloc] forces a new
  /// [_rootService] local, and passing a nullable local to a non-nullable
  /// parameter is a compile error — so the guard cannot fall behind the
  /// resolution the way it did before #189, when one checked service stood
  /// in for five.
  ///
  /// Null (→ the server-add [ShellPlaceholderScreen]) covers a composition
  /// that cannot back the flow: no container at all (tests; the empty
  /// fallback container `runBgeApp` boots on when `createRootContainer`
  /// fails), a partial registration set, or a platform with no
  /// orchestrator.
  Widget? _buildServerAddRoute(BuildContext context) {
    final wellKnownClient = _rootService<WellKnownClient>();
    final versionNegotiator = _rootService<VersionNegotiator>();
    final connectivityService = _rootService<ConnectivityService>();
    final buildInfo = _rootService<BuildInfo>();
    final orchestrator = widget.bootstrapCubit.orchestrator;
    if (wellKnownClient == null ||
        versionNegotiator == null ||
        connectivityService == null ||
        buildInfo == null ||
        orchestrator == null) {
      _logServerAddUnavailable([
        if (wellKnownClient == null) 'WellKnownClient',
        if (versionNegotiator == null) 'VersionNegotiator',
        if (connectivityService == null) 'ConnectivityService',
        if (buildInfo == null) 'BuildInfo',
        if (orchestrator == null) 'ServerOrchestrator',
      ]);
      return null;
    }
    return BlocProvider<ServerOnboardingBloc>(
      create: (_) => ServerOnboardingBloc(
        wellKnownClient: wellKnownClient,
        versionNegotiator: versionNegotiator,
        connectivityService: connectivityService,
        buildInfo: buildInfo,
        orchestrator: orchestrator,
      ),
      child: BlocListener<ServerOnboardingBloc, ServerOnboardingState>(
        listenWhen: (_, current) => current is ServerOnboardingSucceeded,
        listener: (_, _) => widget.bootstrapCubit.onServerRegistered(),
        child: const ServerAddScreen(),
      ),
    );
  }

  /// Reports a server-add composition that cannot back the route (#189),
  /// naming every absent member — the diagnostic exists to spare whoever
  /// reads it from bisecting the composition by hand.
  ///
  /// Error, not warning, and unconditional: this route is reachable in
  /// exactly one bootstrap state. [AppBootstrapNeedsServer] pins every
  /// location to it and every other state redirects away
  /// ([AppRoutes.bootstrapLocations] bounces a ready app to `/home`), so
  /// reaching the fallback means the user is *stuck* on a placeholder with
  /// no retry and no exit. There is no shipped quiet case to filter out:
  /// web never enters that state (its `initialize` always reports
  /// `hasServer: true`), so it never builds this route at all. Tests that
  /// drive the state deliberately are the one caller that reaches the
  /// fallback on purpose, and they assert on this record.
  void _logServerAddUnavailable(List<String> missing) => _log.error(
    'Server-add is unavailable: the composition is missing '
    '${missing.join(', ')}.',
    context: {'missing': missing},
  );

  /// True once bootstrap has left the initializing/failed legs for a state
  /// that only follows successful hydrated-storage init inside
  /// `AppBootstrapCubit` — i.e. `HydratedBloc.storage` is guaranteed
  /// available. `Failed` is excluded: storage init is the first bootstrap
  /// step, so a storage failure surfaces as `Failed` with storage NOT
  /// ready, and this must stay false there.
  static bool _isStorageReady(AppBootstrapState state) =>
      state is AppBootstrapNeedsServer ||
      state is AppBootstrapNeedsAuth ||
      state is AppBootstrapReady;

  /// Constructs the app-level settings controllers exactly once, seeding
  /// their defaults from [BgeApp.themeMode]/[BgeApp.locale] (so an embedder
  /// default is honored on a fresh install, then overridden by any
  /// persisted user selection). In production a storage-ready state
  /// guarantees `HydratedBloc.storage` exists so construction succeeds;
  /// the guard is a defensive net for tests (or an unforeseen state) that
  /// reach a storage-ready state without initializing storage. On failure
  /// it closes any partially constructed pair (no leaked cubit) and leaves
  /// [_settingsControllersCreated] false so [_onBootstrapStateForSettings]
  /// can retry on a later storage-ready state; until then theme/locale fall
  /// back to the widget defaults rather than crashing.
  void _createSettingsControllers() {
    if (_settingsControllersCreated) return;
    ThemeModeCubit? themeModeCubit;
    LocaleCubit? localeCubit;
    try {
      themeModeCubit = ThemeModeCubit(initialThemeMode: widget.themeMode);
      localeCubit = LocaleCubit(initialLocale: widget.locale);
    } on Object {
      // Close whatever was built (e.g. theme succeeded, locale threw) so a
      // failed attempt never leaks a live cubit; the flag stays false to
      // allow a retry.
      unawaited(themeModeCubit?.close());
      unawaited(localeCubit?.close());
      return;
    }
    _settingsControllersCreated = true;
    _themeModeCubit = themeModeCubit;
    _localeCubit = localeCubit;
    // Rebuild MaterialApp in place when either preference changes.
    _themeModeSub = themeModeCubit.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _localeSub = localeCubit.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  /// Retry-capable bootstrap-state handler for lazy settings-controller
  /// creation. Runs on each emission until creation succeeds: ignores
  /// non-storage-ready states, attempts creation on storage-ready ones, and
  /// tears down the subscription (and rebuilds to bind the new values) only
  /// once the controllers exist. A failed attempt keeps the subscription
  /// alive so a later storage-ready state can retry.
  void _onBootstrapStateForSettings(AppBootstrapState state) {
    if (_settingsControllersCreated || !_isStorageReady(state)) return;
    _createSettingsControllers();
    if (!_settingsControllersCreated) return;
    unawaited(_settingsControllerSub?.cancel());
    _settingsControllerSub = null;
    if (mounted) setState(() {});
  }

  /// Renders the #120 settings surface at navigation time. Null (→
  /// [NotYetAvailableScreen], matching the feedback guard) until the
  /// controllers exist. Composes the app-level section (theme; language
  /// only when >1 supported locale) and passes the active server's alias
  /// so the per-server section is shown/omitted correctly — at launch
  /// there are no per-server entries, so that section is empty and omitted
  /// by [SettingsScreen].
  Widget? _buildSettingsRoute(BuildContext context) {
    final themeModeCubit = _themeModeCubit;
    final localeCubit = _localeCubit;
    if (themeModeCubit == null || localeCubit == null) return null;
    return SettingsScreen(
      sections: buildSettingsSections(
        themeModeCubit: themeModeCubit,
        localeCubit: localeCubit,
        supportedLocales: ShellLocalizations.supportedLocales,
      ),
      activeServerAlias:
          widget.bootstrapCubit.activeServerScope?.active?.displayName,
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
    unawaited(_settingsControllerSub?.cancel());
    unawaited(_themeModeSub?.cancel());
    unawaited(_localeSub?.cancel());
    unawaited(_themeModeCubit?.close());
    unawaited(_localeCubit?.close());
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
    // The tree shape is INVARIANT across the settings-controller lifecycle:
    // `MaterialApp.router` is always the direct child of the bootstrap
    // provider, whether or not the controllers exist yet. Reactivity comes
    // from `setState` (the controllers' stream subscriptions), not from a
    // conditionally-inserted `BlocBuilder` — inserting a wrapper when the
    // cubits appear would remount the whole `MaterialApp.router` subtree
    // and discard in-flight Navigator/overlay state. Once a controller
    // exists it owns the value (seed = embedder default, then any persisted
    // selection); before then the widget fallback applies. `locale` uses an
    // explicit null check, not `??`, because a null controller *value*
    // means "follow system" and must not fall back to [BgeApp.locale].
    return BlocProvider.value(
      value: widget.bootstrapCubit,
      child: _buildMaterialApp(
        themeMode: _themeModeCubit?.state ?? widget.themeMode,
        locale: _localeCubit != null ? _localeCubit!.state : widget.locale,
      ),
    );
  }

  Widget _buildMaterialApp({required ThemeMode themeMode, Locale? locale}) {
    return MaterialApp.router(
      onGenerateTitle: (context) =>
          ShellLocalizations.of(context).shellAppTitle,
      theme: widget.theme ?? BgeTheme.light(),
      darkTheme: widget.darkTheme ?? BgeTheme.dark(),
      highContrastTheme:
          widget.highContrastTheme ?? BgeTheme.highContrastLight(),
      highContrastDarkTheme:
          widget.highContrastDarkTheme ?? BgeTheme.highContrastDark(),
      themeMode: themeMode,
      locale: locale,
      routerConfig: _router,
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        final reporter = widget.feedbackReporter;
        // #302: mounted here, above the Navigator, so it survives every
        // route change. The screens that read a re-hydrated cache (the
        // household list and detail) are top-level routes outside the auth
        // ShellRoute, so a trigger inside that shell would be unmounted on
        // exactly the screen showing "couldn't refresh". The widget tracks
        // the active server itself; wrapping this subtree in a
        // StreamBuilder instead would remount the whole app whenever a
        // server came or went.
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
                            ModalBarrier(
                              dismissible: false,
                              // `scrim` rather than a literal black54. The
                              // schemes author this role as a warm near-black
                              // on the walnut hue, so the veil belongs to the
                              // palette instead of being neutral; a palette
                              // swap carries it. It does NOT vary by
                              // brightness or high contrast — every scheme
                              // authors the same value, and the alpha below is
                              // fixed — so do not read more into it than that.
                              color: Theme.of(
                                context,
                              ).colorScheme.scrim.withValues(alpha: 0.54),
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
                                    padding: EdgeInsets.all(
                                      BgeTokens.of(context).spaceMd,
                                    ),
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
        // Unconditional, so the tree shape never changes: the widget
        // handles a null scope and a null connectivity service itself, and
        // an `if` here would remount everything below it the moment either
        // arrived.
        body = SessionRehydrateTrigger(
          scopeSource: () => widget.bootstrapCubit.activeServerScope,
          connectivity: _rootConnectivity(),
          child: body,
        );
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
        HouseholdLocalizations.delegate,
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
///
/// ## User-session scope (#135)
///
/// This listener is also the single authority for the per-(server, user)
/// dependency scope. On any transition into [AuthAuthenticated] it
/// activates the [UserSessionScope] resolved from the active server's
/// container for the session's user id; on any transition into
/// [AuthUnauthenticated] — explicit sign-out *or* a mid-session
/// authentication loss surfaced by the repository — it deactivates it, so
/// per-user singletons and their live queries never outlive a user change.
///
/// Ordering differs by direction. **Sign-in**: activation completes
/// *before* `onAuthenticated()`, so by the time the router advances to
/// home the user's services are installed; if activation fails, the gate
/// does **not** advance — the shell logs the failure and dispatches
/// [AuthSignOutRequested], converging the system to a coherent
/// unauthenticated state (an "authenticated" session whose per-user
/// services can never resolve must not persist silently; signing back in
/// retries from clean state). **Sign-out**: `onSignedOut()` runs first —
/// synchronously, in the listener — and the scope pop follows, so the
/// home subtree is already unmounting when its repositories are disposed
/// and no live widget can dispatch into a disposed service; the pop still
/// closes vended streams regardless of UI disposal, which is what the
/// #135 acceptance relies on. A container with no registered
/// [UserSessionScope] (web until #137; shell tests that don't provide
/// one) skips the scope step entirely, keeping the prior behavior.
class _AuthScope extends StatelessWidget {
  const _AuthScope({
    required this.scope,
    required this.onAuthenticated,
    required this.onSignedOut,
    this.connectivity,
    required this.child,
  });

  final ActiveServerScope? scope;
  final VoidCallback onAuthenticated;
  final VoidCallback onSignedOut;

  /// Device-global connectivity from the root container (#98); null on
  /// compositions without it. Handed to the [AuthBloc], which owns every
  /// decision made on it.
  final ConnectivityService? connectivity;

  final Widget child;

  static final BgeLogger _log = BgeLogger('bge.shell.auth_scope');

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
          create: (_) => AuthBloc(
            authRepository: active.container.get<AuthRepository>(),
            connectivity: connectivity,
          )..add(const AuthSessionCheckRequested()),
          child: BlocListener<AuthBloc, AuthBlocState>(
            // Entry/exit transitions only. `current is AuthAuthenticated`
            // alone was sufficient while equal Authenticated states never
            // re-emitted; #98's verification field makes
            // unverifiedOffline → verified a REAL state change, and this
            // listener re-firing on it would re-run user-session scope
            // activation and re-advance the bootstrap gate on every
            // successful revalidation. Requiring previous to be
            // non-authenticated keeps this listener to what it owns —
            // session start and session end — while verification-only
            // changes flow to presentation via BlocBuilder below.
            listenWhen: (previous, current) =>
                (current is AuthAuthenticated &&
                    previous is! AuthAuthenticated) ||
                current is AuthUnauthenticated,
            listener: (context, state) {
              if (state is AuthAuthenticated) {
                // Captured synchronously — the async handler outlives this
                // listener frame and needs the bloc for the sign-out
                // fallback on activation failure.
                final authBloc = context.read<AuthBloc>();
                // Fire-and-forget from the framework's perspective; the
                // ordering that matters (activation before the gate
                // callback) is owned inside the handler, and the context
                // serializes scope operations, so overlapping handlers
                // cannot interleave scope mutations (#135).
                unawaited(
                  _handleAuthenticated(active, authBloc, state.session.user.id),
                );
              } else if (state is AuthUnauthenticated) {
                // Route first: the gate callback is synchronous here (its
                // original pre-#135 semantics — a throw surfaces through
                // the listener, not as an unhandled zone error), and the
                // home subtree starts unmounting before the scope pop
                // disposes its repositories.
                onSignedOut();
                unawaited(_deactivateSessionScope(active));
              }
            },
            // #141: app resume, the third revalidation trigger. A dispatch
            // trigger rather than chrome, hence a sibling of the banner
            // host; rationale lives on the widget.
            child: AuthLifecycleRevalidationTrigger(
              child: _UnverifiedSessionBannerHost(child: child),
            ),
          ),
        );
      },
    );
  }

  /// Resolves the per-server [UserSessionScope], or null where the
  /// platform composition hasn't registered one (web until #137).
  UserSessionScope? _userSessionScopeOf(ActiveServer active) =>
      active.container.isRegistered<UserSessionScope>()
      ? active.container.get<UserSessionScope>()
      : null;

  /// Activates the user-session scope for [userId], then advances the
  /// bootstrap gate. On activation failure the gate does **not** advance:
  /// the failure is logged and a sign-out is dispatched so the system
  /// converges to unauthenticated instead of stranding an authenticated
  /// session whose per-user services can never resolve (#135) — signing
  /// back in retries activation from a clean scope.
  Future<void> _handleAuthenticated(
    ActiveServer active,
    AuthBloc authBloc,
    String userId,
  ) async {
    final sessionScope = _userSessionScopeOf(active);
    if (sessionScope != null) {
      try {
        await sessionScope.activate(userId);
      } on Object catch (error, stackTrace) {
        _log.error(
          'User-session scope activation failed; signing out to recover',
          error: error,
          stackTrace: stackTrace,
          context: {'serverId': active.serverId},
        );
        // The bloc may have been disposed by a server switch while the
        // activation was in flight; there is nothing to converge then.
        if (!authBloc.isClosed) {
          authBloc.add(const AuthSignOutRequested());
        }
        return;
      }
    }
    try {
      onAuthenticated();
    } on Object catch (error, stackTrace) {
      // The callback runs in an unawaited async continuation; without
      // this guard a throw (e.g. the bootstrap cubit closed during the
      // await above) becomes an unhandled zone error.
      _log.error(
        'Bootstrap gate callback threw after sign-in',
        error: error,
        stackTrace: stackTrace,
        context: {'serverId': active.serverId},
      );
    }
  }

  /// Pops the user-session scope after the gate has routed away (#135):
  /// the departing user's services are disposed and their live streams
  /// closed while the home subtree unmounts. Failures are logged — the
  /// user is already signed out; a scope bug must not resurface as an
  /// unhandled zone error.
  Future<void> _deactivateSessionScope(ActiveServer active) async {
    final sessionScope = _userSessionScopeOf(active);
    if (sessionScope == null) return;
    try {
      await sessionScope.deactivate();
    } on Object catch (error, stackTrace) {
      _log.error(
        'User-session scope deactivation failed',
        error: error,
        stackTrace: stackTrace,
        context: {'serverId': active.serverId},
      );
    }
  }
}

/// Hosts the #98 unverified-session banner above the auth shell's
/// navigator, so it shows on every route INSIDE the auth [ShellRoute]
/// (auth + home) without any route opting in.
///
/// Scope note: routes deliberately placed OUTSIDE the auth shell
/// (settings, feedback, create-household — each documented in
/// `app_router.dart` as needing no [AuthBloc]) do not display it (#145).
///
/// Owns TWO things that must never disagree (#98 review):
///
/// 1. **Dismissal**, per-episode: dismissing hides the banner until the
///    unverified condition next transitions false→true (a new episode).
/// 2. **Inset compensation**: the banner's own SafeArea consumes the top
///    window inset while it shows, so the content below must have that
///    inset REMOVED — otherwise every route's app bar adds a second
///    status-bar-height gap under the banner. When the banner is hidden
///    (condition cleared OR dismissed), the content keeps its inset.
///
/// A banner-internal dismissal (the earlier design) breaks invariant 2:
/// the banner hides itself while the host, unaware, keeps the inset
/// removed, and content underlaps the status bar. Both decisions live
/// here so they cannot diverge.
class _UnverifiedSessionBannerHost extends StatefulWidget {
  const _UnverifiedSessionBannerHost({required this.child});

  final Widget child;

  @override
  State<_UnverifiedSessionBannerHost> createState() =>
      _UnverifiedSessionBannerHostState();
}

class _UnverifiedSessionBannerHostState
    extends State<_UnverifiedSessionBannerHost> {
  bool _dismissedThisEpisode = false;

  static bool _isUnverified(AuthBlocState state) =>
      state is AuthAuthenticated && state.isUnverifiedOffline;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AuthBloc, AuthBlocState>(
      listenWhen: (previous, current) =>
          !_isUnverified(previous) && _isUnverified(current),
      // A new episode rearms dismissal — the condition re-occurring is new
      // information even if the user dismissed the last occurrence.
      listener: (_, _) => setState(() => _dismissedThisEpisode = false),
      buildWhen: (previous, current) =>
          _isUnverified(previous) != _isUnverified(current),
      builder: (context, state) {
        final shellL10n = ShellLocalizations.of(context);
        final showBanner = _isUnverified(state) && !_dismissedThisEpisode;
        return Column(
          children: [
            UnverifiedSessionBanner(
              visible: showBanner,
              message: shellL10n.shellUnverifiedSessionMessage,
              dismissLabel: shellL10n.shellUnverifiedSessionDismiss,
              onDismiss: () => setState(() => _dismissedThisEpisode = true),
            ),
            Expanded(
              // The banner consumed the top inset while it shows; strip it
              // from the content or app bars below inset a second time.
              child: showBanner
                  ? MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: widget.child,
                    )
                  : widget.child,
            ),
          ],
        );
      },
    );
  }
}
