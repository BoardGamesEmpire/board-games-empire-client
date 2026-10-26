import 'dart:async';

import 'package:auth/auth.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart' show AuthUser;
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:server_onboarding/server_onboarding.dart';
import 'package:sync_queue/l10n/sync_localizations.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:ui/ui.dart' show BgePage, UnverifiedSessionBanner;

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
import 'database_recovery_notice.dart';
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
/// Keyboard focus: a route would own it, and above the Navigator nothing
/// does, so the crash flow does it itself. While a draft is pending the
/// app behind the barrier can't take focus, so a field there can't take
/// what is typed and Tab stays in the flow. The prompt and the review
/// surface share one focus scope, which takes focus when the flow opens,
/// again when it swaps between them, and back from a screen that opens
/// behind the barrier. It takes it as a scope, not on
/// the comment field, so no soft keyboard opens unasked. Closing the flow
/// gives focus back to wherever it was before, or to the router's
/// Navigator when that is gone.
///
/// The [DatabaseRecoveryNotice] sits above the crash flow and shuts it out
/// of focus while it is up, so the crash flow takes focus again once the
/// notice is acknowledged. Until then the crash flow's back handler passes
/// system back on to the notice's: a crash that arrived under the notice
/// took priority on the dispatcher after it, and would otherwise arm, then
/// discard, a prompt the user can't see.
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
    this.teardown,
    this.rootContainer,
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

  /// `runBgeApp`'s shared teardown (#384), run on unmount. It closes
  /// [bootstrapCubit] and disposes the platform bootstrap and the root
  /// container. The exit hook runs the same one (#226), so whichever comes
  /// second waits for the first instead of disposing anything twice. Null
  /// means this widget owns none of them; tests injecting their own cubit
  /// close it themselves.
  final Future<void> Function()? teardown;

  /// The app-scope, device-global root container (#72), built by the
  /// platform composition root via
  /// `PlatformBootstrap.createRootContainer` and handed in by
  /// `runBgeApp`. This widget never disposes it: [teardown] does.
  final DependencyContainer? rootContainer;

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

  /// The crash flow's focus scope, shared by the prompt and the review
  /// surface; see the class docs.
  final FocusScopeNode _crashFocus = FocusScopeNode(debugLabel: 'crash flow');

  /// Where focus was when the crash flow took it, given back when it
  /// closes. Non-null only while the flow is up.
  FocusNode? _focusBeforeCrash;
  bool _crashFlowUp = false;

  /// Whether the [DatabaseRecoveryNotice] above the crash flow is up, so
  /// the crash flow's back handler defers to it.
  bool _recoveryNoticeUp = false;

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

  /// The unsent-changes record (#142): written by [_AuthScope], counted for
  /// the auth route. Held here because both reach it, and its count waits
  /// for its writes.
  final _UnsentChanges _unsentChanges = _UnsentChanges();

  /// Each game a detail finds gone (#42), told to every catalog list open:
  /// the one it was opened from, and a browse beneath a search. A list hears
  /// only what is found while it is open, so nothing carries over from one
  /// visit to the next.
  final StreamController<String> _gamesFoundGone =
      StreamController<String>.broadcast();

  /// Whose session home is built for, set by [_AuthScope] (#432).
  ///
  /// Home rebuilds on it. A user switched in place — another tab's sign-in
  /// moving the shared cookie — never leaves home, so nothing else would
  /// rebuild it, and it would go on holding the departed user's services.
  ///
  /// While a switch is under way home is the splash instead. The departing
  /// user's scope is being torn down and the arriving user's is not live
  /// yet, and home's entries open screens over those services.
  ///
  /// Never cleared on sign-out: home unmounts then anyway, and a rebuild
  /// in that frame would only resolve services on their way out.
  final ValueNotifier<_HomeSession> _homeSession = ValueNotifier((
    userId: null,
    switching: false,
  ));

  @override
  void initState() {
    super.initState();
    // See [_selectable]: the region must not mount on the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectionRegionReady) return;
      setState(() => _selectionRegionReady = true);
    });
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
      householdInvitesBuilder: _buildHouseholdInvitesRoute,
      sendHouseholdInviteBuilder: _buildSendHouseholdInviteRoute,
      editHouseholdBuilder: _buildEditHouseholdRoute,
      inviteInboxBuilder: _buildInviteInboxRoute,
      sentInvitesBuilder: _buildSentInvitesRoute,
      createHouseholdBuilder: _buildCreateHouseholdRoute,
      collectionListBuilder: _buildCollectionListRoute,
      gameBrowseBuilder: _buildGameBrowseRoute,
      gameSearchBuilder: _buildGameSearchRoute,
      gameDetailBuilder: _buildGameDetailRoute,
      eventOverviewBuilder: _buildEventOverviewRoute,
      eventGroupBuilder: _buildEventGroupRoute,
      stuckChangesBuilder: _buildStuckChangesRoute,
      dataGatewayListBuilder: _buildDataGatewayListRoute,
      dataGatewayFormBuilder: _buildDataGatewayFormRoute,
    );
    // #76/#105: keep the review slot honest whenever the crash draft
    // empties or changes identity.
    final reporter = widget.feedbackReporter;
    if (reporter != null) {
      reporter.pendingCrashReport.addListener(_handlePendingCrashChanged);
      if (reporter.pendingCrashReport.value != null) _takeCrashFocus();
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
      _giveCrashFocusBack();
      return;
    }
    if (!_crashFlowUp) _takeCrashFocus();
    if (_reviewPreview.value != null && !identical(draft, _reviewOpenedFor)) {
      _closeReview();
    }
  }

  void _takeCrashFocus() {
    _crashFlowUp = true;
    _focusBeforeCrash = FocusManager.instance.primaryFocus;
    _focusCrashFlow();
  }

  /// After the frame that builds the surface now showing, which replaces
  /// whatever in the flow had focus.
  void _focusCrashFlow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _crashFlowUp) _crashFocus.requestFocus();
    });
  }

  /// Takes focus back from a route that opens behind the barrier: a route
  /// focuses itself before it is put in its place, where the flow shuts it
  /// out. The recovery notice above the flow holds focus while it is up,
  /// and focus on the root is the app gone to the background, which gives
  /// focus back to the flow itself on return.
  void _keepCrashFocus(bool hasFocus) {
    if (hasFocus || !mounted || !_crashFlowUp || _recoveryNoticeUp) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus == FocusManager.instance.rootScope) return;
    _crashFocus.requestFocus();
  }

  void _giveCrashFocusBack() {
    if (!_crashFlowUp) return;
    _crashFlowUp = false;
    final before = _focusBeforeCrash;
    _focusBeforeCrash = null;
    // After the frame that lets the app take focus again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Gone (a node keeps its context after its widget is), or shut out
      // (the notice's button, say): focus given there leaves Tab nothing
      // to move through.
      final canReturn =
          before != null &&
          (before.context?.mounted ?? false) &&
          before.canRequestFocus;
      final target = canReturn
          ? before
          : _router.routerDelegate.navigatorKey.currentState?.focusNode;
      target?.requestFocus();
    });
  }

  /// Seeds the #76 review surface from [draft] plus the comment typed on
  /// the compact prompt, remembering the draft identity for #105.
  void _openReview(FeedbackReport draft, String comment) {
    _reviewOpenedFor = draft;
    _reviewPreview.value = FeedbackReportPreview.fromReport(
      draft.withUserComment(comment),
    );
    _focusCrashFlow();
  }

  /// Closes the review surface (back to the compact prompt while a draft
  /// is still pending) and forgets the remembered draft identity.
  void _closeReview() {
    final wasOpen = _reviewPreview.value != null;
    _reviewOpenedFor = null;
    _reviewPreview.value = null;
    if (wasOpen) _focusCrashFlow();
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

  /// Routes an intercepted system back press (#106). Consumes it, so while
  /// the crash flow is up back never reaches the router hidden under the
  /// barrier, unless the recovery notice is up: then it passes the press
  /// on to the notice's handler, which consumes it in turn.
  Future<bool> _handleCrashBack(FeedbackUncaughtErrorReporter reporter) async {
    if (_recoveryNoticeUp) return false;
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
    unsentChanges: _unsentChanges,
    homeSession: _homeSession,
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
      unsentChangesCount: _unsentChanges.countOf(active),
    );
  }

  /// Renders the home route at navigation time — the navigation-drawer
  /// menu (#129). Null (→ [NotYetAvailableScreen]) when no active server
  /// backs the auth bloc the sign-out entry needs. Entry labels are
  /// resolved here from each feature's localizations; each entry's action
  /// runs against the context [HomeScreen] hands back (its State context,
  /// under the auth scope + router), so `context.push` / `context.read`
  /// resolve.
  ///
  /// Rebuilt whenever the session's user changes (#432), so a user switched
  /// in place gets a home built from their own services, and the splash
  /// until then. See [_homeSession].
  Widget? _buildHomeRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    return ValueListenableBuilder<_HomeSession>(
      valueListenable: _homeSession,
      builder: (context, session, _) => session.switching
          ? const SplashScreen()
          : _buildHome(context, active),
    );
  }

  Widget _buildHome(BuildContext context, ActiveServer active) {
    final authL10n = AuthLocalizations.of(context);
    final catalogL10n = GameCatalogLocalizations.of(context);
    final collectionL10n = GameCollectionLocalizations.of(context);
    final eventsL10n = EventsLocalizations.of(context);
    final feedbackL10n = FeedbackLocalizations.of(context);
    final householdL10n = HouseholdLocalizations.of(context);
    final shellL10n = ShellLocalizations.of(context);

    // Only surface households where the household scope is actually
    // installed — the same guard _buildHouseholdListRoute applies.
    // Otherwise the entry would open NotYetAvailableScreen: a menu item
    // for a screen that cannot appear. Post-#135 the household repository
    // lives in the per-USER session scope, so on native this is true
    // exactly while a user session is active — which home's own auth
    // gating already implies. Web's user tier lands the same repository
    // (#137), so the same "exactly while a session is active" reading holds
    // there.
    //
    // The repository ALONE (#269 D4): this entry opens the list, which
    // renders from the local cache. A missing create path (the
    // SyncOperationSender since #121, the HouseholdRemoteDataSource before
    // it) costs the list its create affordance, not its existence — so gating
    // the entry on it, as the create entry this replaces had to, would
    // hide a screen that works.
    //
    // Web was the composition where that reading bit: between #137 and
    // #125 it registered the repository and no household client, so this
    // entry opened a list that was empty by construction. #125 closed that
    // — registerServerNetworkWeb registers the client, as its native
    // counterpart always did.
    //
    // So no shipping composition reaches the repository-without-client case
    // any more, and this gate is now the same width a client-requiring one
    // would be. `HouseholdHydrateInstaller` carries the full statement of
    // which compositions do reach it; in production, none.
    //
    // Left as #269 set it regardless, for two reasons that outlive the
    // reachability: narrowing it would be this widget reversing #269 rather
    // than the issue that owns it, and the wide gate is the one that stays
    // right if a composition without a client ever ships again.
    final container = active.container;
    final canReadHouseholds = container.isRegistered<HouseholdRepository>();
    // #44: the collection list's gate is the household list's — the
    // repository alone, which the user tier registers, so the entry shows
    // exactly while a session is active. A drawer entry rather than a
    // top-level destination until #414 decides those.
    final canReadCollection = container
        .isRegistered<GameCollectionRepository>();
    // #42: browse reads the server, so its gate is the games remote, which
    // the network installer registers per server. A drawer entry, like the
    // collection's (#44): navigation is #414's.
    final canBrowseGames = container.isRegistered<GamesRemoteDataSource>();
    // #497: the events overview's gate is the collection's — the repository
    // alone, which the user tier registers, so the entry shows exactly
    // while a session is active. A drawer entry until #414 makes every one
    // a destination.
    final canReadEvents = container.isRegistered<EventRepository>();
    // #455: the inbox needs the invite client as well, since it reads the
    // server rather than the cache; the household gate keeps it to a live
    // user session, as the households entry is.
    final canReadInvites =
        canReadHouseholds &&
        container.isRegistered<HouseholdInviteRemoteDataSource>();

    HomeScreen home({required bool admin}) => HomeScreen(
      activeServerName: active.displayName,
      // #190: shown while anything is stuck, under the same gate as the
      // screen it opens, so it never leads to one that can't appear.
      notice: _canRecoverStuckChanges(container)
          ? StuckSyncOpsNotice(
              queue: container.get<SyncQueueRepository>(),
              padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceLg),
              onReview: (ctx) => ctx.push(AppRoutes.stuckChanges),
            )
          : null,
      entries: [
        if (canReadCollection)
          HomeMenuEntry(
            id: 'collection',
            icon: Icons.casino_outlined,
            label: collectionL10n.collectionListTitle,
            onSelected: (ctx) => ctx.push(AppRoutes.collection),
          ),
        if (canBrowseGames)
          HomeMenuEntry(
            id: 'games',
            icon: Icons.explore_outlined,
            label: catalogL10n.catalogBrowseTitle,
            onSelected: (ctx) => ctx.push(AppRoutes.games),
          ),
        if (canReadEvents)
          HomeMenuEntry(
            id: 'events',
            icon: Icons.event_outlined,
            label: eventsL10n.eventsTitle,
            onSelected: (ctx) => ctx.push(AppRoutes.events),
          ),
        if (canReadHouseholds)
          HomeMenuEntry(
            id: 'households',
            icon: Icons.groups_outlined,
            label: householdL10n.householdListTitle,
            onSelected: (ctx) => ctx.push(AppRoutes.household),
          ),
        if (canReadInvites)
          HomeMenuEntry(
            id: 'invites',
            icon: Icons.mail_outline,
            label: householdL10n.inviteInboxTitle,
            onSelected: (ctx) => ctx.push(AppRoutes.invites),
          ),
        HomeMenuEntry(
          id: 'send_feedback',
          icon: Icons.feedback_outlined,
          label: feedbackL10n.feedbackComposeTitle,
          onSelected: (ctx) => ctx.push(AppRoutes.feedback),
        ),
        if (admin)
          HomeMenuEntry(
            id: 'admin',
            icon: Icons.admin_panel_settings_outlined,
            label: shellL10n.homeMenuAdmin,
            // Straight to the DataGateway list: it is the only admin screen
            // so far. #274's dashboard takes the entry over and keeps the
            // route.
            onSelected: (ctx) => ctx.push(AppRoutes.adminDataGateways),
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

    // #41: the Admin entry shows only once the session's one-row read of
    // DataGateways has succeeded. A refused read, and one that has not
    // answered yet, both leave it hidden; it appears when the read lands,
    // and goes when a screen later finds the read refused. Moderators can
    // read DataGateways too, so the entry says nothing about changing them:
    // the screen hides its change actions on the first refusal.
    //
    // No access check registered (no DataGateway client, or no user
    // session) is no entry.
    final access = _dataGatewayAccess(container);
    if (access == null) return home(admin: false);
    return ValueListenableBuilder<DataGatewayAccessState>(
      valueListenable: access,
      builder: (_, access, _) =>
          home(admin: access.read == DataGatewayRead.granted),
    );
  }

  /// The #300 retry, for both household screens: the session-scoped
  /// [HouseholdRefresher] the hydrate installer registers, or null where
  /// this composition runs no drain — any container without a household
  /// client, which since #125 is no shipping one (see
  /// `HouseholdHydrateInstaller`).
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
  /// seam at all. Both platforms compose one now (#302 native, #137 web);
  /// shell tests without a user scope do not.
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
  /// On native the rehydrator also holds the sync-queue drain (#121), so
  /// entering the household list drives that too, when it has something to
  /// send. That is a trigger behaving like a trigger; the button
  /// deliberately does not (#300).
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
  /// repository (tests without a scope; no active user session — on either
  /// platform, since #137 gave web the same user tier).
  ///
  /// Two things are deliberately *optional* here where the create route
  /// requires them:
  ///
  /// - the **hydration status** is absent on any composition that runs no
  ///   drain, and the screen reads absent as settled rather than as
  ///   forever-loading;
  /// - the **sender** decides only whether `onCreate` is offered, because
  ///   the create route needs it to send (#121). A container without one
  ///   still gets a working list (#269), which is the whole reason this
  ///   route's gate is narrower than the create route's.
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
      onCreate: container.isRegistered<SyncOperationSender>()
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
      // A pop, not a `go` to the list (#308). The route is the list's child,
      // so there is always a list beneath it: the pushed one on the drawer
      // path, where a `go` would also have dropped home, and the one
      // go_router builds for a `go` straight here.
      onBack: (ctx) => ctx.pop(),
      // #455: the invites entry. The screen itself hides it from a viewer
      // who may not manage invites and for a household the server does not
      // know yet; here it is only whether this composition can reach them.
      invites: _inviteClient(container),
      onOpenInvites: (ctx, id) =>
          unawaited(ctx.push<void>(AppRoutes.householdInvitesOf(id))),
      // #476: Edit. The screen itself hides it from a viewer who may not
      // edit and for a household the server does not know yet; here it is
      // only whether this composition can send the edit, so a composition
      // that can't is not offered a way to a placeholder.
      onEdit: _householdRemote(container) == null
          ? null
          : (ctx, id) =>
                unawaited(ctx.push<void>(AppRoutes.householdEditOf(id))),
      // #569: a member's Invite row. The screen itself offers it only to a
      // member whose household's policy lets members invite; here it is
      // only whether this composition can send one.
      onInvite: _inviteClient(container) == null
          ? null
          : (ctx, id) =>
                unawaited(ctx.push<void>(AppRoutes.householdInviteSendOf(id))),
    );
  }

  /// The per-server invite client (#455), or null where this composition
  /// has none.
  HouseholdInviteRemoteDataSource? _inviteClient(
    DependencyContainer container,
  ) => container.isRegistered<HouseholdInviteRemoteDataSource>()
      ? container.get<HouseholdInviteRemoteDataSource>()
      : null;

  /// The per-server household remote, or null where this composition has
  /// none. An edit is sent through it (#476).
  HouseholdRemoteDataSource? _householdRemote(DependencyContainer container) =>
      container.isRegistered<HouseholdRemoteDataSource>()
      ? container.get<HouseholdRemoteDataSource>()
      : null;

  /// The #476 household-edit wiring. Null (→ [NotYetAvailableScreen])
  /// without an active server, the user-session [HouseholdRepository] that
  /// holds the household and says who is looking, or the household remote
  /// the save is sent through.
  ///
  /// Not gated on the viewer's role: a deep link by someone who may not
  /// edit reaches the screen, which says only owners and admins can.
  /// Leaving after a save is a pop: the route is the detail screen's
  /// child, and the detail screen shows the cached answer. A household
  /// that is gone, or an edit the server refuses, runs the households'
  /// own pass, as the refresh banner's retry does.
  Widget? _buildEditHouseholdRoute(BuildContext context, String householdId) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    final remote = _householdRemote(container);
    if (remote == null || !container.isRegistered<HouseholdRepository>()) {
      return null;
    }

    return EditHouseholdScreen(
      householdId: householdId,
      repository: container.get<HouseholdRepository>(),
      remote: remote,
      onRefresh: _householdRetry(container),
      onSaved: (ctx) => ctx.pop(),
    );
  }

  /// The #455 household-invites wiring. Null (→ [NotYetAvailableScreen])
  /// without an active server, the invite client, or the user-session
  /// [HouseholdRepository] that says who is looking.
  ///
  /// Not gated on the viewer's role: a deep link by someone the server
  /// refuses reaches the screen, which says only owners and admins can see
  /// the invites.
  Widget? _buildHouseholdInvitesRoute(
    BuildContext context,
    String householdId,
  ) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    final invites = _inviteClient(container);
    if (invites == null || !container.isRegistered<HouseholdRepository>()) {
      return null;
    }

    return HouseholdInviteListScreen(
      householdId: householdId,
      remote: invites,
      repository: container.get<HouseholdRepository>(),
      onInvite: (ctx) => unawaited(
        ctx.push<void>(AppRoutes.householdInviteSendOf(householdId)),
      ),
    );
  }

  /// The #455 send-invite wiring. Same null contract as
  /// [_buildHouseholdInvitesRoute].
  ///
  /// The form offers roles by who is looking and, for a member, by the
  /// household's member invite policy (#569). Both are cache reads; the
  /// screen takes the answers rather than reading them, so it stays
  /// synchronous. A send refused with 403 runs the households' own pass, as
  /// an edit refused with 403 does, and the form redraws from what it
  /// brings back.
  ///
  /// The route is the detail screen's child. An owner or admin leaves after
  /// a send by a pop, back to the invites they pushed it from, which read
  /// themselves again as they come back into view, or to the household. A
  /// member is replaced by the Sent screen instead, because they can't read
  /// the household's invites; Back from it still returns to the household
  /// (#569).
  Widget? _buildSendHouseholdInviteRoute(
    BuildContext context,
    String householdId,
  ) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    final invites = _inviteClient(container);
    if (invites == null || !container.isRegistered<HouseholdRepository>()) {
      return null;
    }

    return _SendHouseholdInviteRoute(
      // A new household is a new read of who is looking. Without the key, a
      // `go` between two households' forms would offer the first one's
      // roles until the second read lands.
      key: ValueKey<String>(householdId),
      householdId: householdId,
      repository: container.get<HouseholdRepository>(),
      remote: invites,
      onRefresh: _householdRetry(container),
    );
  }

  /// The #455 invite-inbox wiring. Same null contract as
  /// [_buildHouseholdInvitesRoute].
  ///
  /// After an accept, the household arrives through the hydrate: one pass,
  /// or two when one was already running (see `refreshAfterJoin`). No
  /// refresher registered means no drain to run, and the household comes
  /// with the next pass that does.
  ///
  /// Both are resolved here, as [_householdRetry] does, not when the accept
  /// answers. By then the session may have ended, and a lookup would throw
  /// or reach the next user's scope.
  Widget? _buildInviteInboxRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    final invites = _inviteClient(container);
    if (invites == null || !container.isRegistered<HouseholdRepository>()) {
      return null;
    }

    final refresher = container.isRegistered<HouseholdRefresher>()
        ? container.get<HouseholdRefresher>()
        : null;
    final status = container.isRegistered<HouseholdHydrationStatus>()
        ? container.get<HouseholdHydrationStatus>()
        : null;

    return InviteInboxScreen(
      remote: invites,
      onJoined: refresher == null
          ? null
          : (_) => refreshAfterJoin(refresher, status),
      onOpenHousehold: (ctx, id) =>
          unawaited(ctx.push<void>(AppRoutes.householdDetailOf(id))),
      onOpenSent: (ctx) => unawaited(ctx.push<void>(AppRoutes.invitesSent)),
    );
  }

  /// The #487 sent invites: the same container lookups as
  /// [_buildInviteInboxRoute], and null under the same conditions, so the
  /// two routes are available together. The screen never reads the
  /// [HouseholdRepository]; it is asked for as the inbox's gate is, because
  /// the user tier registers it, so the route opens only in a live session.
  Widget? _buildSentInvitesRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    final invites = _inviteClient(container);
    if (invites == null || !container.isRegistered<HouseholdRepository>()) {
      return null;
    }

    return SentInvitesScreen(remote: invites);
  }

  /// The #129 create-household wiring: resolves the [HouseholdRepository]
  /// and the [SyncOperationSender] (both per-user session scope, #135,
  /// #121) from the *active server's* scoped container — not
  /// [BgeApp.rootContainer]. Null (→ [NotYetAvailableScreen]) when no
  /// active server is resolvable or its container lacks either (tests
  /// without a scope; no active user session). Both platforms register the
  /// sender in their user tier, so a real session on either reaches this
  /// route. The inline send goes through it, the delivery path the queue
  /// drain shares, so the two can't both deliver one create.
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
        !container.isRegistered<SyncOperationSender>()) {
      return null;
    }

    return CreateHouseholdScreen(
      repository: container.get<HouseholdRepository>(),
      sender: container.get<SyncOperationSender>(),
      // #271: the new household's own screen takes the place of the spent
      // form, so back can never land on it again (#162).
      //
      // `pushReplacement`, not `replace` (#271 D1): both drop the top-most
      // page, but `replace` reuses its page key and runs no animation —
      // that is for swapping a route for a variant of itself, not for
      // substituting an unrelated screen.
      //
      // Either way in, the list route is beneath the form, so back pops onto
      // it: the pushed one on the drawer path (list → FAB → create), and the
      // one go_router builds for a `go` straight to the create route, which
      // is the list's child (#308).
      onCreated: (ctx, householdId) {
        // #300 D3/D9: a create makes the local set stale by definition, so
        // the next entry to the list re-hydrates rather than waiting out
        // the remaining window. Cleared here, before the navigation, and
        // not inside the household feature — the invalidation belongs to
        // *mutation*, and this is where mutations are already wired, which
        // is what gives #122's membership mutations the same hook.
        //
        // Absent on a composition that runs no drain (a container with no
        // household client): nothing to invalidate, and a create must not
        // care.
        if (container.isRegistered<HouseholdHydrationStatus>()) {
          container.get<HouseholdHydrationStatus>().markStale();
        }
        ctx.pushReplacement(AppRoutes.householdDetailOf(householdId));
      },
    );
  }

  /// The collection list's retry (#44): the session-scoped
  /// [GameCollectionRefresher] the hydrate installer registers, or null
  /// where this composition runs no collection hydrate, in which case the
  /// banner offers nothing to press.
  ///
  /// The collection's own pass, not the [SessionRehydrator], for
  /// [_householdRetry]'s reason: the rehydrator drops a pass while one is
  /// running, and a button someone pressed must not do nothing.
  Future<void> Function()? _collectionRetry(DependencyContainer container) =>
      container.isRegistered<GameCollectionRefresher>()
      ? container.get<GameCollectionRefresher>().refresh
      : null;

  /// A collection pass that starts after the call, for a discard (#190):
  /// the list's retry joins a pass in flight, which may have merged the
  /// discarded row's page already.
  Future<void> Function()? _collectionRefreshAfterChange(
    DependencyContainer container,
  ) => container.isRegistered<GameCollectionRefresher>()
      ? container.get<GameCollectionRefresher>().refreshAfterChange
      : null;

  /// The collection list's entry trigger (#44): the session's
  /// [SessionRehydrator], through the shell's shared guard, as
  /// [_householdEntryRefresh] does. The staleness window in the registry
  /// decides whether any work happens. Once #121 registers the sync-queue
  /// drain, entering the list drives that too.
  VoidCallback? _collectionEntryRefresh(DependencyContainer container) {
    if (!container.isRegistered<SessionRehydrator>()) return null;
    final rehydrator = container.get<SessionRehydrator>();
    return () => startDetachedRehydrate(
      trigger: 'collection_entry',
      resolve: () => rehydrator,
    );
  }

  /// The collection-list wiring (#44): resolves the
  /// [GameCollectionRepository] (user-session scope) from the active
  /// server's container, plus the optional [GameCollectionHydrationStatus],
  /// the retry and the entry trigger. Null (→ [NotYetAvailableScreen]) when
  /// no active server is resolvable or its container has no repository.
  ///
  /// Everything is resolved when the route is built rather than held on
  /// this state, as [_buildHouseholdListRoute] does: a callback held across
  /// a session change would reach a disposed scope's hydrator. A mounted
  /// route needs nothing more, because the list's bloc keeps what its first
  /// build gave it, and a session ending under it closes the list's stream
  /// while the auth redirect pops the route.
  ///
  /// No `onOpen` yet: rows stay inert content until #46 gives them a
  /// detail route (#44).
  Widget? _buildCollectionListRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    if (!container.isRegistered<GameCollectionRepository>()) return null;

    final hydration = container.isRegistered<GameCollectionHydrationStatus>()
        ? container.get<GameCollectionHydrationStatus>().watch()
        : null;

    return GameCollectionListScreen(
      repository: container.get<GameCollectionRepository>(),
      hydration: hydration,
      onRetry: _collectionRetry(container),
      onEnter: _collectionEntryRefresh(container),
    );
  }

  /// The games cache (#42): the user-session [GameRepository], or null where
  /// no user session is active. The catalog screens read the server without
  /// it, and have nothing to show offline.
  static GameRepository? _gamesCache(DependencyContainer container) =>
      container.isRegistered<GameRepository>()
      ? container.get<GameRepository>()
      : null;

  /// Opens one game from a catalog screen (#42). A push, so leaving the
  /// detail returns to the list or the search the user came from.
  static void _openGame(BuildContext context, String gameId) =>
      unawaited(context.push<void>(AppRoutes.gameDetailOf(gameId)));

  /// Tells the catalog lists open that a game is gone: see
  /// [_gamesFoundGone]. A detail answering after the app is gone tells no
  /// one.
  void _reportGameGone(String gameId) {
    if (!_gamesFoundGone.isClosed) _gamesFoundGone.add(gameId);
  }

  /// The active server's container, where it holds the per-server
  /// [GamesRemoteDataSource]: the gate every #42 catalog route shares. Null
  /// (→ [NotYetAvailableScreen]) when no active server is resolvable or it
  /// has no games remote.
  ///
  /// Resolved per route build, as the other screens are: anything held
  /// across a session change would reach a disposed scope's cache.
  DependencyContainer? _catalogContainer() {
    final container =
        widget.bootstrapCubit.activeServerScope?.active?.container;
    if (container == null || !container.isRegistered<GamesRemoteDataSource>()) {
      return null;
    }
    return container;
  }

  /// The #42 browse screen: the games remote and the optional games cache,
  /// behind [_catalogContainer]'s gate.
  Widget? _buildGameBrowseRoute(BuildContext context) {
    final container = _catalogContainer();
    if (container == null) return null;

    return GameBrowseScreen(
      remote: container.get<GamesRemoteDataSource>(),
      cache: _gamesCache(container),
      gone: _gamesFoundGone.stream,
      onOpen: _openGame,
      onSearch: (ctx) => unawaited(ctx.push<void>(AppRoutes.gameSearch)),
    );
  }

  /// The #42 search screen. Same gate as [_buildGameBrowseRoute], plus the
  /// DataGateways' names where the user may read them.
  ///
  /// No `onImport`: importing a DataGateway result is #43's, and until it
  /// supplies one those rows stay inert.
  Widget? _buildGameSearchRoute(BuildContext context) {
    final container = _catalogContainer();
    if (container == null) return null;

    return GameSearchScreen(
      remote: container.get<GamesRemoteDataSource>(),
      cache: _gamesCache(container),
      sourceNames: _dataGatewayNames(container),
      gone: _gamesFoundGone.stream,
      onOpen: _openGame,
    );
  }

  /// The #42 detail screen for [gameId]. Same gate as
  /// [_buildGameBrowseRoute].
  ///
  /// No `onAdd`: adding a game to the collection is #45's, and until it
  /// supplies one the screen offers no add.
  Widget? _buildGameDetailRoute(BuildContext context, String gameId) {
    final container = _catalogContainer();
    if (container == null) return null;

    return GameDetailScreen(
      gameId: gameId,
      remote: container.get<GamesRemoteDataSource>(),
      cache: _gamesCache(container),
      onGone: _reportGameGone,
    );
  }

  /// The events screens' retry (#497): the session-scoped [EventRefresher]
  /// the hydrate installer registers, or null where this composition runs
  /// no event hydrate, in which case the banner offers nothing to press.
  ///
  /// The events' own pass, not the [SessionRehydrator], for
  /// [_householdRetry]'s reason: the rehydrator drops a pass while one is
  /// running, and a button someone pressed must not do nothing.
  Future<void> Function()? _eventsRetry(DependencyContainer container) =>
      container.isRegistered<EventRefresher>()
      ? container.get<EventRefresher>().refresh
      : null;

  /// The overview's entry trigger (#497): the session's [SessionRehydrator],
  /// through the shell's shared guard, as [_collectionEntryRefresh] does.
  /// The staleness window in the registry decides whether any work happens.
  VoidCallback? _eventsEntryRefresh(DependencyContainer container) {
    if (!container.isRegistered<SessionRehydrator>()) return null;
    final rehydrator = container.get<SessionRehydrator>();
    return () => startDetachedRehydrate(
      trigger: 'events_entry',
      resolve: () => rehydrator,
    );
  }

  /// The active server's container, where it holds the user-session
  /// [EventRepository]: the gate both #497 routes share. Null (→
  /// [NotYetAvailableScreen]) when no active server is resolvable or it has
  /// no repository.
  ///
  /// Resolved per route build, as [_buildCollectionListRoute] does: a
  /// callback held across a session change would reach a disposed scope's
  /// hydrator. A mounted route needs nothing more, because its bloc keeps
  /// what its first build gave it, and a session ending under it closes the
  /// event stream while the auth redirect pops the route.
  DependencyContainer? _eventsContainer() {
    final container =
        widget.bootstrapCubit.activeServerScope?.active?.container;
    if (container == null || !container.isRegistered<EventRepository>()) {
      return null;
    }
    return container;
  }

  /// The cached households, for each event row's household name (#497), or
  /// null where the session has no household cache.
  static Stream<List<Household>>? _eventHouseholds(
    DependencyContainer container,
  ) => container.isRegistered<HouseholdRepository>()
      ? container.get<HouseholdRepository>().watchHouseholds()
      : null;

  /// What the event hydrate is doing, or null where none runs.
  static Stream<EventHydration>? _eventHydration(
    DependencyContainer container,
  ) => container.isRegistered<EventHydrationStatus>()
      ? container.get<EventHydrationStatus>().watch()
      : null;

  /// The #497 events overview, behind [_eventsContainer]'s gate, with the
  /// optional households, status, retry and entry trigger.
  ///
  /// No `onOpen` and no `onCreate`: rows stay inert until #498 gives them a
  /// detail route, and there is no create button until #499.
  Widget? _buildEventOverviewRoute(BuildContext context) {
    final container = _eventsContainer();
    if (container == null) return null;

    return EventOverviewScreen(
      repository: container.get<EventRepository>(),
      households: _eventHouseholds(container),
      hydration: _eventHydration(container),
      onOpenGroup: (ctx, group) =>
          unawaited(ctx.push<void>(AppRoutes.eventGroupOf(group.name))),
      onRetry: _eventsRetry(container),
      onEnter: _eventsEntryRefresh(container),
    );
  }

  /// The #497 page for the group named [segment]. Same gate as
  /// [_buildEventOverviewRoute], and null for a segment that names no group.
  ///
  /// No entry trigger: the page is pushed above the overview, which fired
  /// one on its own entry.
  Widget? _buildEventGroupRoute(BuildContext context, String segment) {
    final group = EventGroup.values.where((g) => g.name == segment).firstOrNull;
    final container = _eventsContainer();
    if (group == null || container == null) return null;

    return EventGroupScreen(
      group: group,
      repository: container.get<EventRepository>(),
      households: _eventHouseholds(container),
      hydration: _eventHydration(container),
      onRetry: _eventsRetry(container),
    );
  }

  /// Reads every DataGateway's name, by id, for the search screen (#42), or
  /// null where the session has not learned that the user may read
  /// DataGateways. Ordinary users may not (`read:data_gateway` is
  /// staff-only), and their search results then carry no DataGateway name.
  ///
  /// Decided when the route is built. A user whose access check answers
  /// after they opened search sees names the next time they open it.
  static Future<Map<String, String>> Function()? _dataGatewayNames(
    DependencyContainer container,
  ) {
    final access = _dataGatewayAccess(container);
    if (access == null ||
        access.value.read != DataGatewayRead.granted ||
        !container.isRegistered<DataGatewayRemoteDataSource>()) {
      return null;
    }
    final remote = container.get<DataGatewayRemoteDataSource>();
    return () => readDataGatewayNames(remote);
  }

  /// Whether [container] holds what the #190 retry-or-discard screen needs:
  /// the session's queue, and both repositories a discard undoes through.
  /// The user tier registers all three, so this holds exactly while a
  /// session is active, on both platforms.
  static bool _canRecoverStuckChanges(DependencyContainer container) =>
      container.isRegistered<SyncQueueRepository>() &&
      container.isRegistered<GameCollectionRepository>() &&
      container.isRegistered<HouseholdRepository>();

  /// The #190 retry-or-discard wiring. Null (→ [NotYetAvailableScreen])
  /// when no active server is resolvable or [_canRecoverStuckChanges] says
  /// no.
  ///
  /// A retry goes through the session's [SyncQueueDrain] where one runs,
  /// which is native, and inline through the [SyncOperationSender] where
  /// none does, which is web until #447. A discard refreshes the cache it
  /// undid through that cache's refresher, the pass a retry button runs, so
  /// the undone row comes back as the server has it.
  ///
  /// Resolved per route build, like every route here, so nothing is held
  /// across a session change.
  Widget? _buildStuckChangesRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    if (!_canRecoverStuckChanges(container)) return null;

    return StuckSyncOpsScreen(
      recovery: SyncRecovery(
        queue: container.get<SyncQueueRepository>(),
        collection: container.get<GameCollectionRepository>(),
        households: container.get<HouseholdRepository>(),
        sender: container.isRegistered<SyncOperationSender>()
            ? container.get<SyncOperationSender>()
            : null,
        drain: container.isRegistered<SyncQueueDrain>()
            ? container.get<SyncQueueDrain>().drainAfterChange
            : null,
        refreshCollection: _collectionRefreshAfterChange(container),
        refreshHouseholds: _householdRetry(container),
      ),
    );
  }

  /// The session's [DataGatewayAccess], or null where the session runs no
  /// access check (#41).
  static DataGatewayAccess? _dataGatewayAccess(DependencyContainer container) =>
      container.isRegistered<DataGatewayAccess>()
      ? container.get<DataGatewayAccess>()
      : null;

  /// The #41 DataGateway list: the per-server [DataGatewayRemoteDataSource]
  /// and the session's [DataGatewayAccess] from the active server's
  /// container. Null (→ [NotYetAvailableScreen]) when no active server is
  /// resolvable or it has no DataGateway client.
  ///
  /// Guarded on the client alone, not on access: a deep link by a user the
  /// server refuses reaches the screen, which says so (#41).
  ///
  /// The forms are pushed. The list reads itself again whenever it comes back
  /// into view, including the list go_router builds beneath a form reached
  /// by a `go` straight to it.
  Widget? _buildDataGatewayListRoute(BuildContext context) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    if (!container.isRegistered<DataGatewayRemoteDataSource>()) return null;

    return DataGatewayListScreen(
      remote: container.get<DataGatewayRemoteDataSource>(),
      access: _dataGatewayAccess(container),
      onAdd: (ctx) => unawaited(ctx.push<void>(AppRoutes.dataGatewayAdd)),
      onEdit: (ctx, id) =>
          unawaited(ctx.push<void>(AppRoutes.dataGatewayEditOf(id))),
    );
  }

  /// The #41 DataGateway add form, or the edit form for [dataGatewayId].
  /// Same resolution and null contract as [_buildDataGatewayListRoute].
  ///
  /// Leaving after a save is a pop either way in: the forms are children of
  /// the list route, so a `go` straight to one builds the list beneath it.
  Widget? _buildDataGatewayFormRoute(
    BuildContext context,
    String? dataGatewayId,
  ) {
    final active = widget.bootstrapCubit.activeServerScope?.active;
    if (active == null) return null;

    final container = active.container;
    if (!container.isRegistered<DataGatewayRemoteDataSource>()) return null;

    return DataGatewayFormScreen(
      remote: container.get<DataGatewayRemoteDataSource>(),
      access: _dataGatewayAccess(container),
      editingId: dataGatewayId,
      onDone: (ctx) => ctx.pop(),
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
  /// working — and [NotYetAvailableScreen]'s app bar gives it the same back
  /// button as the real flow (#308).
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
    _crashFocus.dispose();
    _homeSession.dispose();
    unawaited(_settingsControllerSub?.cancel());
    unawaited(_themeModeSub?.cancel());
    unawaited(_localeSub?.cancel());
    unawaited(_themeModeCubit?.close());
    unawaited(_localeCubit?.close());
    unawaited(_gamesFoundGone.close());
    final deepLinkHandler = widget.deepLinkHandler;
    if (widget.disposeDeepLinkHandlerOnDispose && deepLinkHandler != null) {
      unawaited(deepLinkHandler.dispose());
    }
    final activeLocaleController = widget.activeLocaleController;
    if (widget.disposeActiveLocaleControllerOnDispose &&
        activeLocaleController != null) {
      activeLocaleController.dispose();
    }
    final teardown = widget.teardown;
    if (teardown != null) unawaited(teardown());
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

  /// The app-wide text-selection region (#322), on the platforms that get one.
  ///
  /// Wraps the router's content — so every route, dialog and SnackBar inside
  /// it is selectable — rather than the whole builder output, which would
  /// also swallow the crash overlay. That overlay keeps its own opt-in; see
  /// [FeedbackReviewScreen].
  ///
  /// **The `Overlay.wrap` is load-bearing, and the order is too.** The reason
  /// is the one already written out below, at the crash overlay: this slot
  /// sits above the router's Navigator, so there is no Overlay ancestor here.
  /// `SelectableRegion.build` asserts `debugCheckHasOverlay`, so a bare
  /// `SelectionArea` throws on the first frame — and `SelectionArea` wrapped
  /// *around* `Overlay.wrap` throws for the same reason, since the region
  /// still has no Overlay above it. It has to be this way round.
  ///
  /// ## Why it waits a frame
  ///
  /// Mounting the region on the first frame crashed the web app on load,
  /// every load, before any interaction (#322 follow-up). The sequence:
  /// `SelectableRegion` registers a focus node → `applyFocusChangesIfNeeded`
  /// notifies `View`'s scope listener → the web engine calls
  /// `requestViewFocusChange` → the browser fires focus **synchronously** →
  /// `didChangeViewFocus` → `findFirstFocus` → the traversal policy sorts
  /// every focus node and reads `FocusNode.rect` on each. That runs during
  /// the build phase, before layout, so `rect` asserts `hasSize` on a render
  /// object that has not been laid out — and the region's own node is the
  /// one it hits, because the nearest render object below its `Focus` is
  /// inside `SelectableRegion` itself.
  ///
  /// It only bites on the *first* view-focus acquisition, which is why one
  /// post-frame callback is enough: by the second frame the view already
  /// holds focus, so registering the node no longer triggers a view-focus
  /// change, and the subtree is laid out anyway.
  ///
  /// Deferred on every platform rather than just web. The bug is web-only,
  /// but one code path is worth more here than a platform branch nobody
  /// tests — and the cost is a single extra rebuild while the splash screen
  /// is up. `bge_app_selection_test.dart` pins both halves.
  ///
  /// Arguably a framework bug — reading `rect` mid-build is not something a
  /// caller can defend against — and worth removing if Flutter guards it.
  ///
  /// ## Platform gating
  ///
  /// Unlike the rest of this builder, the tree shape here does depend on a
  /// condition — and the gate reads the *resolved* theme, which `MaterialApp`
  /// swaps on a brightness or high-contrast change. Four themes that
  /// disagreed on `platform` would therefore flip this mid-session and
  /// remount the whole router subtree, discarding Navigator stack, form input
  /// and scroll positions on an OS appearance change.
  ///
  /// [_debugThemePlatformsAgree] rules that out rather than trusting it: all
  /// four are built by `BgeTheme` from one `_build` and agree by
  /// construction, and an embedder that hand-rolls them and gets it wrong
  /// fails loudly in debug instead of shipping an intermittent remount.
  ///
  /// One further consequence of that `Overlay.wrap`, easy to miss because it
  /// is invisible today: it is now the app's **root** overlay. Before this,
  /// the router's Navigator owned the outermost one, so
  /// `Overlay.of(context, rootOverlay: true)` resolved there and its entries
  /// came down with a route pop. They now resolve above the Navigator and
  /// survive it — so a `MenuAnchor(useRootOverlay: true)`, or anything else
  /// reaching for the root overlay to host a layer, would strand its entry
  /// over the next screen. Nothing in the app does that yet.
  ///
  /// Anything drag-interactive added below this — a reorderable collection
  /// list is the likely first one — must wrap itself in
  /// `SelectionContainer.disabled`, or its drag and the selection drag will
  /// fight over the same gesture. Nothing enforces that rule yet; #338
  /// tracks giving it a mechanism.
  /// Whether a frame has been laid out, so the region may mount. See
  /// [_selectable] — this is not a readiness nicety, it is a crash fix.
  bool _selectionRegionReady = false;

  Widget _selectable(BuildContext context, Widget content) {
    if (!BgeSelection.isEnabledOn(Theme.of(context).platform)) return content;
    if (!_selectionRegionReady) return content;
    return Overlay.wrap(child: SelectionArea(child: content));
  }

  /// Whether every theme this app can resolve reports the same `platform`.
  ///
  /// Debug-only, and it exists for [_selectable]: that gate reads the
  /// resolved theme, so a disagreement here is not a cosmetic inconsistency
  /// but a mid-session remount of everything below the router. Cheap to
  /// assert, effectively impossible to notice otherwise.
  bool _debugThemePlatformsAgree() {
    final platforms = <TargetPlatform>{
      (widget.theme ?? BgeTheme.light()).platform,
      (widget.darkTheme ?? BgeTheme.dark()).platform,
      (widget.highContrastTheme ?? BgeTheme.highContrastLight()).platform,
      (widget.highContrastDarkTheme ?? BgeTheme.highContrastDark()).platform,
    };
    return platforms.length == 1;
  }

  Widget _buildMaterialApp({required ThemeMode themeMode, Locale? locale}) {
    assert(
      _debugThemePlatformsAgree(),
      'BgeApp was given themes that disagree on ThemeData.platform. The '
      'text-selection region (#322) is gated on the resolved theme, so the '
      'app would gain or lose it — remounting the entire router subtree — '
      'the moment the OS switched appearance. Override all four themes or '
      'none.',
    );
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
        final content = _selectable(context, child ?? const SizedBox.shrink());
        final reporter = widget.feedbackReporter;
        // #302: mounted here, above the Navigator, so it survives every
        // route change. The screens that read a re-hydrated cache (the
        // household list and detail) are routes outside the auth
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
                            child: ExcludeFocus(
                              excluding: draft != null,
                              child: content,
                            ),
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
                              color: Theme.of(context).colorScheme.scrim
                                  .withValues(alpha: 0.54),
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
                            //
                            // The selection region in [_selectable] wraps
                            // itself for the same reason, one level up. It
                            // is a separate Overlay on purpose: this one
                            // must unmount with the crash flow, and the
                            // content below must stay selectable whether or
                            // not a draft is pending.
                            //
                            // One focus scope holds whichever surface is
                            // showing (see the class docs), filling the
                            // Stack as each surface did on its own. The
                            // keys keep a swap remounting the overlay, as
                            // it did when each was the Stack's own child.
                            Positioned.fill(
                              child: FocusScope(
                                node: _crashFocus,
                                onFocusChange: _keepCrashFocus,
                                child: reviewPreview == null
                                    // #69 compact "ask each time" prompt.
                                    ? Overlay.wrap(
                                        key: const ValueKey(
                                          'bge_app.crash_flow.prompt',
                                        ),
                                        child: Align(
                                          alignment: Alignment.bottomCenter,
                                          child: Padding(
                                            padding: EdgeInsets.all(
                                              BgeTokens.of(context).spaceMd,
                                            ),
                                            child: ValueListenableBuilder<bool>(
                                              valueListenable:
                                                  _promptDismissArmed,
                                              builder: (context, dismissArmed, _) {
                                                return CrashReportPrompt(
                                                  report: draft,
                                                  // #106: after a first intercepted
                                                  // back, surface the localized
                                                  // live-region dismiss hint.
                                                  showDismissHint: dismissArmed,
                                                  onSubmit:
                                                      reporter.service.submit,
                                                  // #76: seed the review slot from
                                                  // the draft plus the typed
                                                  // comment; the overlay then swaps
                                                  // to the full surface below.
                                                  onReviewDetails: (comment) =>
                                                      _openReview(
                                                        draft,
                                                        comment,
                                                      ),
                                                  onDiscard: () =>
                                                      _discardCrashDraft(
                                                        reporter,
                                                      ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      )
                                    // #76 full review & redaction surface.
                                    : Overlay.wrap(
                                        key: const ValueKey(
                                          'bge_app.crash_flow.review',
                                        ),
                                        child: FeedbackReviewScreen(
                                          preview: reviewPreview,
                                          onSubmit: reporter.service.submit,
                                          // Back out of review → compact prompt.
                                          onCancel: _closeReview,
                                          // Dismiss after a terminal outcome →
                                          // clear every slot.
                                          onClose: () =>
                                              _discardCrashDraft(reporter),
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
              );
        // #428: the notice of a server database rebuilt during boot. Above
        // the router, so the redirects of the first screens cannot remove
        // it, and unconditional, so the tree shape never changes.
        body = DatabaseRecoveryNotice(
          bootstrapCubit: widget.bootstrapCubit,
          backButtonDispatcher: _router.backButtonDispatcher,
          onShown: () => _recoveryNoticeUp = true,
          // A crash flow under the notice couldn't take focus while it was
          // up; see the class docs.
          onAcknowledged: () {
            _recoveryNoticeUp = false;
            if (_crashFlowUp) _focusCrashFlow();
          },
          fallbackFocus: () =>
              _router.routerDelegate.navigatorKey.currentState?.focusNode,
          child: body,
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
        GameCollectionLocalizations.delegate,
        GameCatalogLocalizations.delegate,
        EventsLocalizations.delegate,
        SyncLocalizations.delegate,
        DataGatewayLocalizations.delegate,
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
/// new one bound to the new server's repository. When [scope] is null
/// (bootstrap has not succeeded) or has no active server, the child
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
/// retries from clean state). The gate also does not advance when the
/// world changed *during* the activation, in any of three ways: the user
/// switched servers, auth was superseded (a revalidation rejecting the
/// token, a sign-out, a fresh sign-in attempt), or the session scope this
/// handler built was torn down and not yet replaced — the last of which a
/// fast sign-out → sign-back-in produces while the user id still matches.
/// The state that justified advancing has been superseded, nothing would
/// re-emit to correct a wrong advance, and whatever superseded it owns the
/// convergence, so this leg takes no corrective action either (#176). That
/// makes the sign-in leg conditional on the world still holding when the
/// await returns, not merely on activation succeeding. For the same
/// reason the failure leg's recovery sign-out is conditional too: it
/// exists to stop a live authenticated session being stranded without
/// services, and dispatches only while there is still such a session. **Sign-out**: `onSignedOut()` runs first —
/// synchronously, in the listener — and the scope pop follows, so the
/// home subtree is already unmounting when its repositories are disposed
/// and no live widget can dispatch into a disposed service; the pop still
/// closes vended streams regardless of UI disposal, which is what the
/// #135 acceptance relies on. A container with no registered
/// [UserSessionScope] (shell tests that don't provide one; any composition
/// with no per-user services) skips the scope step entirely, keeping the
/// prior behavior.
///
/// The same two transitions are reported to [unsentChanges] (#142), which
/// keeps the record behind the sign-in screen's unsent-changes notice.
///
/// ## A user switched in place (#432)
///
/// A third transition runs both legs: another user's session arriving over
/// a live one, which on web is another tab's sign-in moving the shared
/// cookie. The first user's session ends — not deliberately, and without
/// routing to the sign-in screen — and the second's starts, with a
/// one-time notice once it is live.
class _AuthScope extends StatefulWidget {
  const _AuthScope({
    required this.scope,
    required this.onAuthenticated,
    required this.onSignedOut,
    this.connectivity,
    required this.unsentChanges,
    required this.homeSession,
    required this.child,
  });

  final ActiveServerScope? scope;
  final VoidCallback onAuthenticated;
  final VoidCallback onSignedOut;

  /// Device-global connectivity from the root container (#98); null on
  /// compositions without it. Handed to the [AuthBloc], which owns every
  /// decision made on it.
  final ConnectivityService? connectivity;

  /// Told when a session starts and ends (#142).
  final _UnsentChanges unsentChanges;

  /// Told when a user switch begins and when a session goes live (#432);
  /// see `_BgeAppState._homeSession`.
  final ValueNotifier<_HomeSession> homeSession;

  final Widget child;

  @override
  State<_AuthScope> createState() => _AuthScopeState();
}

/// Stateful only to hold [_authEpoch] (#383) and the listener's record of
/// sessions (#432); nothing here affects build.
class _AuthScopeState extends State<_AuthScope> {
  static final BgeLogger _log = BgeLogger('bge.shell.auth_scope');

  /// Counts the auth transitions this scope's listener has acted on.
  ///
  /// The supersession token for a handler that outlived its listener
  /// frame, and the only one available: server and user id describe the
  /// *world*, and a sign-out followed by a same-user sign-in leaves both
  /// reading exactly as they did, so neither can tell this handler's
  /// session from its successor's. `AuthResponse` carries no per-sign-in
  /// field to compare either — `token` is null on web by design (#291) and
  /// `expiresAt` is null until the session endpoint confirms it.
  ///
  /// Same mechanism as `WebAuthRepositoryImpl._sessionEpoch` (#146, #285),
  /// one layer up: bumped before dispatch, captured by the handler,
  /// re-compared on resume.
  ///
  /// Mutated without [setState] deliberately — it is not build-affecting
  /// state, and a rebuild here would re-subscribe the [StreamBuilder]
  /// below for nothing.
  int _authEpoch = 0;

  /// The session the listener last started and has not seen end (#432).
  ///
  /// The listener is handed only the new state, so this is how it knows a
  /// session is open when another user's arrives. Keyed by server as well:
  /// on native a server switch builds a new bloc whose first session is a
  /// different user on a different server, which is not a switch on this
  /// one.
  ({String serverId, String userId})? _openSession;

  /// The session the listener last started, kept past its end (#432).
  ///
  /// A tab another tab signed out shows the sign-in form, and a sign-in
  /// there later reaches this tab over no open session. This is how the
  /// listener tells whether that sign-in is a different user from the one
  /// the tab last showed.
  ({String serverId, String userId})? _lastSession;

  /// The state the transition the listener is acting on came from.
  ///
  /// The listener is handed only the new state, so `listenWhen` records the
  /// old one for it; `BlocListener` calls the listener straight after
  /// `listenWhen` answers true, for the same transition.
  AuthBlocState? _arrivedFrom;

  @override
  Widget build(BuildContext context) {
    final scope = widget.scope;
    if (scope == null) return widget.child;

    return StreamBuilder<ActiveServer?>(
      stream: scope.watchActive(),
      initialData: scope.active,
      builder: (context, snapshot) {
        final active = snapshot.data;
        if (active == null) return widget.child;

        return BlocProvider<AuthBloc>(
          // Keyed on serverId: a switch unmounts the old bloc (closing it
          // and its repository subscription) and builds a fresh one. The
          // close is asynchronous — `AuthBloc.close` awaits its
          // subscriptions — so a handler still in flight over the old bloc
          // must not read `isClosed` as "did the server change" (#176). The
          // startup
          // session check is dispatched on creation so every freshly-keyed
          // bloc restores its own server's session.
          key: ValueKey('auth_bloc_${active.serverId}'),
          create: (_) => AuthBloc(
            authRepository: active.container.get<AuthRepository>(),
            connectivity: widget.connectivity,
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
            //
            // The same reasoning on the way out (#142): unauthenticated
            // carries a cause, so a cause-only change would be a real
            // state change too, and must not re-run the sign-out work.
            //
            // And one transition between two authenticated states (#432):
            // another user's session over a live one. On web every tab
            // shares one cookie, so a sign-in in another tab moves this
            // tab's session to another user with no sign-out in between.
            // Keyed on the user id, so a new session for the same user is
            // not a change.
            //
            // The unauthenticated arm stays `previous is!
            // AuthUnauthenticated` rather than narrowing to `previous is
            // AuthAuthenticated` (#208): a sign-out passes through
            // `AuthLoading` first, so the narrower test would miss every
            // ordinary one.
            listenWhen: (previous, current) {
              final acts =
                  (current is AuthAuthenticated &&
                      previous is! AuthAuthenticated) ||
                  (current is AuthUnauthenticated &&
                      previous is! AuthUnauthenticated) ||
                  (current is AuthAuthenticated &&
                      previous is AuthAuthenticated &&
                      current.session.user.id != previous.session.user.id);
              if (acts) _arrivedFrom = previous;
              return acts;
            },
            listener: (context, state) {
              // Bumped for every transition this listener acts on, before
              // anything is dispatched, so a handler's captured value is
              // stale the moment the next one starts (#383).
              var epoch = ++_authEpoch;
              if (state is AuthAuthenticated) {
                final userId = state.session.user.id;
                final departing = _openSession;
                final switching =
                    departing != null &&
                    departing.serverId == active.serverId &&
                    departing.userId != userId;
                if (switching) {
                  _endSessionInPlace(context, active);
                  // A second bump: the end and the start are two
                  // transitions, and a handler from either must see the
                  // other as newer.
                  epoch = ++_authEpoch;
                }
                // Another user's session reaching a tab resting signed out:
                // this tab's own sign-in passes through `AuthLoading`, so
                // one arriving straight from the sign-in form came from
                // another tab (#432). The same user signing back in is no
                // change of account, and needs no notice.
                final arrivedFrom = _arrivedFrom;
                final lastSession = _lastSession;
                final replacing =
                    departing == null &&
                    (arrivedFrom is AuthUnauthenticated ||
                        arrivedFrom is AuthOperationFailure) &&
                    lastSession != null &&
                    lastSession.serverId == active.serverId &&
                    lastSession.userId != userId;
                _openSession = (serverId: active.serverId, userId: userId);
                _lastSession = _openSession;
                // Before activation, so a recovery sign-out's count waits
                // for this record (#142).
                widget.unsentChanges.sessionStarted(active, userId);
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
                  _handleAuthenticated(
                    active,
                    authBloc,
                    userId,
                    epoch,
                    onLive: switching || replacing
                        ? _switchNotice(context, state.session.user)
                        : null,
                  ),
                );
              } else if (state is AuthUnauthenticated) {
                _openSession = null;
                widget.unsentChanges.sessionEnded(
                  active,
                  deliberately: state.cause == SignOutCause.user,
                );
                // Route first: the gate callback is synchronous here (its
                // original pre-#135 semantics — a throw surfaces through
                // the listener, not as an unhandled zone error), and the
                // home subtree starts unmounting before the scope pop
                // disposes its repositories.
                widget.onSignedOut();
                unawaited(_deactivateSessionScope(active));
              }
            },
            // #141: app resume, the third revalidation trigger. A dispatch
            // trigger rather than chrome, hence a sibling of the banner
            // host; rationale lives on the widget.
            child: AuthLifecycleRevalidationTrigger(
              child: _UnverifiedSessionBannerHost(child: widget.child),
            ),
          ),
        );
      },
    );
  }

  /// Resolves the per-server [UserSessionScope], or null where the
  /// platform composition hasn't registered one. Both platforms register one
  /// now (#135 native, #137 web); a composition without per-user services
  /// still legitimately has none.
  UserSessionScope? _userSessionScopeOf(ActiveServer active) =>
      _serverService<UserSessionScope>(active);

  /// Whether [active] is still the server the app is living in.
  ///
  /// The authoritative staleness signal for a handler that outlived its
  /// listener frame, and *not* interchangeable with `authBloc.isClosed`: a
  /// server switch unmounts the old provider, but [AuthBloc.close] awaits
  /// two subscription cancellations before `super.close()`, so the departed
  /// bloc goes on answering `isClosed == false` — and `state` goes on
  /// answering with the departed server's session — well past the unmount
  /// (measured in a widget test: still false a second later). The scope
  /// answers synchronously and is never behind (#176).
  bool _serverStillActive(ActiveServer active) =>
      widget.scope?.active?.serverId == active.serverId;

  /// Whether [authBloc] still reports an authenticated session for
  /// [userId]. Checked alongside [_serverStillActive], never instead of it.
  bool _stillAuthenticatedAs(AuthBloc authBloc, String userId) {
    if (authBloc.isClosed) return false;
    final current = authBloc.state;
    return current is AuthAuthenticated && current.session.user.id == userId;
  }

  /// Activates the user-session scope for [userId], then advances the
  /// bootstrap gate. On activation failure the gate does **not** advance:
  /// the failure is logged and a sign-out is dispatched so the system
  /// converges to unauthenticated instead of stranding an authenticated
  /// session whose per-user services can never resolve (#135) — signing
  /// back in retries activation from a clean scope.
  ///
  /// [onLive] runs once the session is live and the gate has been told, and
  /// not at all if it never goes live.
  Future<void> _handleAuthenticated(
    ActiveServer active,
    AuthBloc authBloc,
    String userId,
    int epoch, {
    VoidCallback? onLive,
  }) async {
    final sessionScope = _userSessionScopeOf(active);
    if (sessionScope != null) {
      try {
        await sessionScope.activate(userId);
      } on Object catch (error, stackTrace) {
        // Recovery is this handler's to dispatch only while it still owns
        // the session. Three ways it stops owning it:
        //
        // Superseded: another transition has been acted on since. This is
        // the only one that catches a sign-out followed by a same-user
        // sign-back-in — server and user id both read live for the *newer*
        // session, so without the epoch this leg signs out a session that
        // has just been activated successfully (#383). The scope cannot
        // answer it either: by the time this runs the re-activation has
        // typically landed, so `activeUserId` reads as this user.
        //
        // Server gone: the switch closed the bloc's subtree, and nothing
        // over there is waiting on a sign-out.
        //
        // Auth moved on: a sign-out that landed while the activation was
        // failing has already converged the system, and a fresh sign-in
        // still in `AuthLoading` will converge on its own — its own
        // handler owns whatever follows. Dispatching into either costs a
        // network round trip and a second onSignedOut/deactivate pair for
        // a session that is already gone (#176).
        final superseded = _authEpoch != epoch;
        final serverLive = _serverStillActive(active);
        final authLive = _stillAuthenticatedAs(authBloc, userId);
        final recovering = !superseded && serverLive && authLive;
        _log.error(
          recovering
              ? 'User-session scope activation failed; signing out to recover'
              : 'User-session scope activation failed; a newer session owns '
                    'the recovery',
          error: error,
          stackTrace: stackTrace,
          // Predicates, never user ids — the success leg's log channel
          // holds to the same rule.
          context: {
            'serverId': active.serverId,
            'superseded': superseded,
            'serverStillActive': serverLive,
            'authStillLive': authLive,
          },
        );
        if (recovering) {
          // Not the user's request, so the sign-in screen keeps the notice
          // if they have changes waiting (#142).
          authBloc.add(
            const AuthSignOutRequested(cause: SignOutCause.sessionLost),
          );
        }
        return;
      }
    }
    // The activation above is awaited, and three things can go stale under
    // it. The gate advances only if all three still hold, and it takes
    // no corrective action either way — whatever superseded this handler
    // owns the convergence (#176).
    //
    // The server: the user can switch servers, which unmounts this
    // handler's whole auth subtree. Its captured bloc does not notice
    // promptly (see [_serverStillActive]), so advancing here would route
    // to home on behalf of a server nobody is looking at.
    //
    // Auth: a revalidation can reject the restored token, or a sign-out
    // can land. Advancing on a superseded state routes to home for a
    // session the server has already disowned, and nothing re-emits to
    // correct it — a value-equal AuthUnauthenticated is deduped by bloc
    // state equality.
    //
    // The scope: a sign-out queued behind this activation tears the
    // session scope down, and `activeUserId` is null *before* this line
    // runs. Not because the teardown finishes first — it does not — but
    // because both implementations null the id in the first synchronous
    // statement of teardown (`ContainerUserSessionScope._teardown`,
    // `ServerContextImpl._teardownUserScope`), and the serialization
    // chain runs that prefix before the activation caller resumes. The
    // re-activation that would restore the id is queued behind the
    // teardown and lands after it (measured, not assumed). The read
    // below sits in the window between them, which is why there is no
    // deactivation here. But on a fast sign-out → sign-back-in that
    // same queueing means auth alone reads "authenticated, same user"
    // while no user scope exists at all; routing home there mounts the
    // per-user subtree over services nobody has installed. The second
    // handler advances the gate itself once its own activation lands.
    final serverLive = _serverStillActive(active);
    final authLive = _stillAuthenticatedAs(authBloc, userId);
    final scopeLive =
        sessionScope == null || sessionScope.activeUserId == userId;
    if (!serverLive || !authLive || !scopeLive) {
      _log.warn(
        'Auth or its user scope changed during user-session activation; '
        'leaving the bootstrap gate on the auth leg',
        // Which of the three failed, and whether the bloc outlived the
        // activation at all, are different diagnoses with different
        // follow-up — a bare "something changed" breadcrumb cannot tell
        // them apart. Reported as predicates rather than ids: no user id
        // has ever been written to this log channel.
        context: {
          'serverId': active.serverId,
          'serverStillActive': serverLive,
          'authStillLive': authLive,
          'scopeStillLive': scopeLive,
          'authBlocClosed': authBloc.isClosed,
        },
      );
      return;
    }
    // Ahead of the gate callback, so a home it routes to is built for this
    // user. A user switched in place is already on home, and this is what
    // rebuilds it (#432). Not once this scope has unmounted: the app may be
    // gone, and the notifier with it, while a route builds home afresh
    // anyway.
    if (mounted) widget.homeSession.value = (userId: userId, switching: false);
    try {
      widget.onAuthenticated();
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
    if (mounted) onLive?.call();
  }

  /// Ends the open session without leaving the signed-in shell, because
  /// another user's session has replaced it (#432).
  ///
  /// The unauthenticated arm's work minus its routing: no `onSignedOut()`,
  /// which would flash the sign-in screen for a session the user never left.
  /// Not a deliberate sign-out, so the departing user's unsent-changes
  /// record stays (#142).
  ///
  /// Screens opened under the departing user are closed first, for the
  /// reason the sign-out arm routes first: they hold repositories the scope
  /// pop is about to dispose. Going home does that, since every such screen
  /// is pushed above it. Home itself shows the splash until the new user's
  /// scope is live, and is rebuilt for them then (see
  /// `_BgeAppState._homeSession`).
  void _endSessionInPlace(BuildContext context, ActiveServer active) {
    widget.unsentChanges.sessionEnded(active, deliberately: false);
    widget.homeSession.value = (userId: null, switching: true);
    GoRouter.maybeOf(context)?.go(AppRoutes.home);
    unawaited(_deactivateSessionScope(active));
  }

  /// The one-time notice that this tab now shows [user]'s account (#432),
  /// or null where there is nowhere to show it.
  ///
  /// The messenger and the copy are taken now, while [context] is current;
  /// the notice itself waits until the new session is live.
  VoidCallback? _switchNotice(BuildContext context, AuthUser user) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return null;
    final message = ShellLocalizations.of(context)
        .shellSessionSwitchedNotice(user.username);
    return () => messenger.showSnackBar(SnackBar(content: Text(message)));
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

/// Whose session home is built for, and whether a switch to another user is
/// under way (#432).
typedef _HomeSession = ({String? userId, bool switching});

/// Resolves [T] from [active]'s per-server container, or null where the
/// composition registers none. The per-server counterpart of
/// `_BgeAppState._rootService`.
T? _serverService<T extends Object>(ActiveServer active) =>
    active.container.isRegistered<T>() ? active.container.get<T>() : null;

/// The shell's half of the unsent-changes notice (#142).
///
/// Keeps the per-server [UnsentChangesNoticeRepository] told whose session
/// is open, and reads its count for the sign-in screen. Session start
/// records the user. A sign-out the user asked for retires them. Every
/// other ending leaves them recorded, so the sign-in screen can say how many
/// of their changes are waiting. That covers the server rejecting the
/// session, the shell's recovery sign-out after a failed activation, and
/// the app being killed while they were signed in.
///
/// Recorded at the start rather than the end because one ending has no
/// user in memory: a stored session rejected at the next launch never
/// reaches [AuthAuthenticated].
///
/// ## Order
///
/// The writes are fire-and-forget, since neither may hold up routing. They
/// run one after another, though, and a count waits for every write asked
/// for before it. So a deliberate sign-out's retire lands before the
/// sign-in screen reads, and so does the record of a session whose
/// activation failed, whatever order the database runs statements in.
///
/// Failures are logged with the server and never the user id, the rule the
/// auth scope's channel has always kept, and never thrown. A failed write
/// logs its error by type alone, since the error's own text can carry the
/// id the write bound. Web registers no repository (#144, #447), so there
/// all of this is a no-op.
class _UnsentChanges {
  static final BgeLogger _log = BgeLogger('bge.shell.unsent_changes');

  /// How long the sign-in screen may hold its splash for the count. A cold
  /// read opens the server database first, and that takes well under this.
  /// A read that runs past it is a fault: it's logged, and the screen shows
  /// without the notice rather than keeping the user from signing in.
  static const Duration _countBudget = Duration(seconds: 2);

  /// The user whose session last started, until it ends.
  ///
  /// Not keyed by server. A server switch can carry it over, but on the new
  /// server a session has to start before one can end deliberately, and the
  /// start replaces it.
  String? _openUserId;

  /// The last record write asked for; each one waits for the one before.
  Future<void> _writes = Future<void>.value();

  void sessionStarted(ActiveServer active, String userId) {
    _openUserId = userId;
    _write(
      active,
      'Recording the session start for unsent changes failed',
      (notice) => notice.recordSessionStarted(userId),
    );
  }

  void sessionEnded(ActiveServer active, {required bool deliberately}) {
    final userId = _openUserId;
    _openUserId = null;
    if (!deliberately || userId == null) return;
    _write(
      active,
      'Recording the sign-out for unsent changes failed',
      (notice) => notice.recordSignedOut(userId),
    );
  }

  /// The sign-in screen's count of unsent changes on [active], or null
  /// where there's nothing to count them with. A failed or overdue read is
  /// logged and counts zero: the user came to sign in, and an error there
  /// would be about a notice they never saw.
  Future<int> Function()? countOf(ActiveServer active) {
    final notice = _serverService<UnsentChangesNoticeRepository>(active);
    if (notice == null) return null;
    Future<int> afterWrites() async {
      await _writes;
      return notice.unsentChangesCount();
    }

    return () async {
      try {
        return await afterWrites().timeout(_countBudget);
      } on Object catch (error, stackTrace) {
        _log.error(
          'Unsent-changes count failed; the sign-in screen shows no notice',
          error: error,
          stackTrace: stackTrace,
          context: {'serverId': active.serverId},
        );
        return 0;
      }
    };
  }

  void _write(
    ActiveServer active,
    String failure,
    Future<void> Function(UnsentChangesNoticeRepository notice) write,
  ) {
    final notice = _serverService<UnsentChangesNoticeRepository>(active);
    if (notice == null) return;
    _writes = _writes.then((_) async {
      try {
        await write(notice);
      } on Object catch (error, stackTrace) {
        // The type only: a database error's text lists the statement's bound
        // values, and both writes bind the user id.
        _log.error(
          failure,
          stackTrace: stackTrace,
          context: {
            'serverId': active.serverId,
            'cause': error.runtimeType.toString(),
          },
        );
      }
    });
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

/// Resolves who is looking and the household's member invite policy, then
/// shows the send-invite form (#455, #569).
///
/// Cache reads that take a frame or two. Until both have answered once the
/// page shows a spinner under the form's own title, so the route does not
/// flash a different screen first. A failed role read is a viewer the cache
/// cannot place, and a household list that fails before it answers is a
/// policy nobody knows; the form answers either with its not-allowed text.
///
/// Asked again whenever the household's roster or the households change,
/// the household detail screen's way: on a deep link the cache may be cold
/// when the route opens, and the hydrate's rows are what let the form open.
/// A role or a policy changed under the open form reaches it the same way,
/// so a switch to `Off` replaces a member's form with the reason. Once a
/// stream has answered, an error on it leaves the last answer standing.
class _SendHouseholdInviteRoute extends StatefulWidget {
  const _SendHouseholdInviteRoute({
    required this.householdId,
    required this.repository,
    required this.remote,
    this.onRefresh,
    super.key,
  });

  final String householdId;
  final HouseholdRepository repository;
  final HouseholdInviteRemoteDataSource remote;

  /// Runs the households' own pass after a send refused with 403.
  final Future<void> Function()? onRefresh;

  @override
  State<_SendHouseholdInviteRoute> createState() =>
      _SendHouseholdInviteRouteState();
}

class _SendHouseholdInviteRouteState extends State<_SendHouseholdInviteRoute> {
  StreamSubscription<List<HouseholdMember>>? _members;
  StreamSubscription<List<Household>>? _households;

  /// The newest household list, once [_householdsAnswered].
  List<Household>? _latestHouseholds;
  bool _householdsAnswered = false;

  /// Who is looking under which policy, once both have answered. A record,
  /// so a null role or policy still reads as an answer.
  ({HouseholdRole? role, MemberInvitePolicy? policy})? _viewer;

  /// Role reads started, and the newest one applied. Each event starts a
  /// read, and one that resolves after a newer one is dropped.
  int _readsStarted = 0;
  int _readApplied = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reread());
    _members = widget.repository
        .watchMembers(widget.householdId)
        .listen(
          (_) => unawaited(_reread()),
          // The last answer stands.
          onError: (Object _) {},
        );
    _households = widget.repository.watchHouseholds().listen(
      (households) {
        _latestHouseholds = households;
        _householdsAnswered = true;
        unawaited(_reread());
      },
      onError: (Object _) {
        // The last answer stands, or with none yet, no policy is known.
        if (_householdsAnswered) return;
        _householdsAnswered = true;
        unawaited(_reread());
      },
    );
  }

  @override
  void dispose() {
    unawaited(_members?.cancel());
    unawaited(_households?.cancel());
    super.dispose();
  }

  /// Reads the role again, and shows it with the newest policy, so the two
  /// change on screen together.
  Future<void> _reread() async {
    final read = ++_readsStarted;
    final role = await _readRole();
    if (!mounted || read < _readApplied || !_householdsAnswered) return;
    _readApplied = read;
    final household = _latestHouseholds
        ?.where((household) => household.id == widget.householdId)
        .firstOrNull;
    setState(
      () => _viewer = (
        role: role,
        policy: household?.settings?.memberInvitePolicy,
      ),
    );
  }

  Future<HouseholdRole?> _readRole() async {
    try {
      final member = await widget.repository.getCurrentUserMember(
        widget.householdId,
      );
      return member?.role;
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewer = _viewer;
    if (viewer == null) {
      return BgePage(
        title: Text(HouseholdLocalizations.of(context).inviteSendTitle),
        width: BgePageWidth.pane,
        centerVertically: true,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return SendHouseholdInviteScreen(
      householdId: widget.householdId,
      viewerRole: viewer.role,
      memberInvitePolicy: viewer.policy,
      remote: widget.remote,
      onRefresh: widget.onRefresh,
      onSent: (ctx) => ctx.pop(),
      onMemberSent: (ctx) => ctx.pushReplacement(AppRoutes.invitesSent),
    );
  }
}
