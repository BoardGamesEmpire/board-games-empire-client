import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import '../deep_links/deep_link_handler.dart';
import '../deep_links/pending_deep_link_holder.dart';
import '../i18n/active_locale.dart';
import '../observability/feedback_uncaught_error_reporter.dart';
import '../observability/global_error_hooks.dart';
import '../observability/shell_observability.dart';
import '../widgets/bge_app.dart';
import '../widgets/build_error_view.dart';
import 'app_bootstrap_cubit.dart';
import 'platform_bootstrap.dart';

/// Boots the application. This is the entire contract of each app's
/// `main.dart`: perform platform-specific setup, then hand a
/// [PlatformBootstrap] to this function.
///
/// Sequencing: observability (breadcrumb capture + last-error slot) →
/// binding init → **root container** → active-locale slot (#33) →
/// global error hooks → deep-link reception (#10) → construct
/// [AppBootstrapCubit] → start (not await) its bootstrap → `runApp`.
/// Breadcrumbs attach first so every later step — including bootstrap
/// failures — is already captured for feedback reports.
///
/// The root container (issue #72) is the app-scope, device-global
/// [DependencyContainer], built by the platform composition root via
/// [PlatformBootstrap.createRootContainer]. It is acquired *before* the
/// error hooks and before the failure-prone platform [initialize], so
/// device-global services (client version #35, feedback #69) exist even
/// on a failed boot. Implementations must not throw (they register
/// degraded values instead); as a belt-and-braces guard, a throw here is
/// breadcrumbed at error level and boot proceeds on an empty fallback —
/// error capture is never coupled to root-container success. The app
/// widget owns the container's lifecycle
/// ([BgeApp.disposeRootContainerOnDispose]), since this function has no
/// teardown point of its own.
///
/// The active-locale slot (issue #33) is an [ActiveLocaleController]
/// seeded with the raw OS locale — the best available value before the
/// first frame. It is created, registered as [ActiveLocaleReader], and
/// handed to [BgeApp] for capture as a single unit, and only when no
/// reader is already registered. A platform module or test seam that
/// pre-registers its own reader stays authoritative for consumers AND
/// owns its own locale updates — [runBgeApp] then wires no capture (the
/// controller is null), so it can never leave the registered reader on
/// its seed while a detached controller tracks the real locale. When
/// [runBgeApp] does own the slot, [BgeApp]'s `ActiveLocaleCapture`
/// corrects it to the **negotiated** locale at the first frame and
/// tracks OS locale changes thereafter, so consumers (the feedback
/// environment below; gateway `locale` hints later) read the locale the
/// UI actually renders in, not a language the app may have no
/// translations for. The app widget owns the controller's lifecycle
/// ([BgeApp.disposeActiveLocaleControllerOnDispose]) when it owns the
/// controller.
///
/// Deep-link reception (issue #10): the platform's out-of-band source is
/// created via [PlatformBootstrap.createDeepLinkSource] *after* the error
/// hooks (so handler faults are captured) and *before* the cubit's
/// [PlatformBootstrap.initialize] — the underlying plugin must be
/// instantiated early to buffer the cold-start launch link. When a source
/// exists (native), a [DeepLinkHandler] normalizes each link into the
/// [PendingDeepLinkHolder]; the holder is created on **every** platform,
/// web included, because #83's auth-gate stashes redirect-bounced
/// locations into the same slot. Draining the slot is #82/#83 scope. The
/// app widget owns the handler's lifecycle
/// ([BgeApp.disposeDeepLinkHandlerOnDispose]), mirroring the container.
///
/// Error capture (issue #34) is [installGlobalErrorHooks]: the two
/// catch-all surfaces the Flutter team recommends, with **no custom
/// Zone** — per official guidance (3.3+), `PlatformDispatcher.onError`
/// supersedes `runZonedGuarded`. The pre-binding window here is a single
/// pure-Dart call ([ShellObservability.initialize]) and needs no zone.
///
/// Error presentation (issue #66) is [installBuildErrorView], replacing
/// the default in-build failure UI with a localized, accessible view.
/// Capture (#34) and presentation (#66) are deliberately separate units;
/// both are installed here because they mutate process globals, which
/// belongs in bootstrap, not in widget builds (see [installBuildErrorView]
/// for the flutter_test invariant that forbids the in-widget placement).
///
/// Theming (#32): the four theme slots ([theme], [darkTheme],
/// [highContrastTheme], [highContrastDarkTheme]) are pure passthrough
/// override seams — production `main.dart`s leave them null and [BgeApp]
/// defaults them from `BgeTheme`, keeping the apps thin. [themeMode]
/// stays [ThemeMode.system]; the user-facing selection + persistence is
/// #78.
///
/// The splash route renders while bootstrap runs; hydrated-storage
/// initialization happens inside the cubit so its failures surface on the
/// retryable error screen instead of as a blank frame.
/// [hydratedStorageInitializer] is forwarded to the cubit — the same
/// injectable seam [AppBootstrapCubit] already exposes, here so shell
/// tests can drive the real `runBgeApp` without touching real Hive IO;
/// production callers leave it null for the cubit's real default.
/// [uncaughtErrorReporter] is the crash-reporting override seam: when
/// supplied, it owns reporting (the hooks use it verbatim) and no prompt
/// machinery is wired. When null — the production default — the shell
/// composes the device-global [FeedbackServiceImpl], registers it into
/// the root container, and wires a [FeedbackUncaughtErrorReporter] into
/// both the hooks and [BgeApp]'s "ask each time" prompt overlay (#69).
Future<void> runBgeApp({
  required PlatformBootstrap platformBootstrap,
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeData? highContrastTheme,
  ThemeData? highContrastDarkTheme,
  ThemeMode themeMode = ThemeMode.system,
  List<LocalizationsDelegate<dynamic>> additionalLocalizationsDelegates =
      const [],
  UncaughtErrorReporter? uncaughtErrorReporter,
  HydratedStorageInitializer? hydratedStorageInitializer,
}) async {
  ShellObservability.initialize();
  WidgetsFlutterBinding.ensureInitialized();

  // Root container before the hooks: #69 resolves the crash reporter from
  // it, and a container that only exists after a successful bootstrap
  // could never stamp a failed-boot feedback report.
  //
  // This is the one window not covered by the global error hooks (they
  // install just below) and there is deliberately no Zone — a tradeoff of
  // the container-before-hooks ordering. The awaited call surfaces
  // synchronous throws and the awaited future's rejection into the catch
  // below; the residual gap is a *detached* async error during the build,
  // which the createRootContainer contract forbids (its work must be
  // synchronous or fully awaited).
  DependencyContainer rootContainer;
  try {
    rootContainer = await platformBootstrap.createRootContainer();
  } on Object catch (error, stackTrace) {
    // Contract violation — implementations must not throw. Breadcrumb it
    // (observability is already live) and boot on a working empty
    // container: error capture must never be coupled to root-container
    // success. The fallback is empty, so failed-boot consumers of the
    // container resolve-or-default (see createRootContainer's contract).
    BgeLogger('bge.shell.root_container').error(
      'Root container build failed; booting with an empty fallback '
      'container',
      error: error,
      stackTrace: stackTrace,
    );
    rootContainer = DependencyContainerImpl();
  }

  // #33: the active-locale slot, seeded with the raw OS locale (the best
  // available value pre-frame; BgeApp's capture corrects it to the
  // negotiated locale at the first frame).
  //
  // Create, register, AND wire capture as a single unit — only when no
  // reader is already registered. If a platform module or test seam has
  // pre-registered one, it stays authoritative for consumers AND owns
  // its own locale updates: we must not overwrite it, and — critically —
  // must not wire BgeApp's capture to a fresh controller no consumer
  // reads (that would leave the pre-registered reader stuck on its seed
  // while a detached controller silently tracks the negotiated locale).
  // So a foreign reader means `activeLocaleController` stays null and
  // BgeApp wires no capture.
  final ActiveLocaleController? activeLocaleController =
      rootContainer.isRegistered<ActiveLocaleReader>()
      ? null
      : ActiveLocaleController(
          WidgetsBinding.instance.platformDispatcher.locale,
        );
  if (activeLocaleController != null) {
    rootContainer.registerSingleton<ActiveLocaleReader>(activeLocaleController);
  }
  final registeredLocaleReader = rootContainer.get<ActiveLocaleReader>();

  // #69: compose the device-global FeedbackService and register it —
  // on whichever container boot proceeds with, INCLUDING the empty
  // fallback, so feedback works on a failed boot (that failure is
  // exactly what the first report will be about). Resolve-or-default
  // throughout, per the createRootContainer contract: BuildInfo degrades
  // to unknown, a missing platform sink degrades to the RAM stand-in.
  final buildInfo = rootContainer.isRegistered<BuildInfo>()
      ? rootContainer.get<BuildInfo>()
      : BuildInfo.unknown;
  final feedbackService = FeedbackServiceImpl(
    breadcrumbSource: () => ShellObservability.breadcrumbs.snapshot(),
    environmentSource: () => FeedbackEnvironment(
      appVersion: buildInfo.version,
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      // #33: the ACTIVE (negotiated) locale, read per report (the
      // closure is evaluated lazily, so runtime locale changes are
      // reflected) from the authoritative registered reader — the
      // locale the UI renders in, not the raw OS preference.
      locale: registeredLocaleReader.languageTag,
      // Alpha-minimal, no plugin, and web-safe (this file compiles for
      // web, so dart:io is off the table here). OS *version* enrichment
      // can ride a platform-module-registered probe later.
      deviceInfo: <String, dynamic>{
        'operatingSystem': kIsWeb ? 'web' : defaultTargetPlatform.name,
      },
    ),
    // No transport until a server context with an authenticated session
    // exists — #37 wires the resolver (and the drainPending trigger)
    // when auth lands. Until then every approved report goes to the
    // durable sink.
    transportResolver: () => null,
    sink: rootContainer.isRegistered<FeedbackSink>()
        ? rootContainer.get<FeedbackSink>()
        : MemoryFeedbackSink(),
  );
  if (!rootContainer.isRegistered<FeedbackService>()) {
    rootContainer.registerSingleton<FeedbackService>(feedbackService);
  }
  // Resolve the authoritative instance from the container — an injected
  // root module / test seam may have registered its own FeedbackService,
  // and the hooks and prompt must submit through the same instance that
  // rootContainer.get<FeedbackService>() returns, not the one composed
  // just above.
  final registeredFeedbackService = rootContainer.get<FeedbackService>();

  // Explicit override wins and owns reporting; otherwise the shell's
  // feedback reporter feeds both the hooks and the prompt overlay.
  final feedbackReporter = uncaughtErrorReporter == null
      ? FeedbackUncaughtErrorReporter(service: registeredFeedbackService)
      : null;

  installGlobalErrorHooks(
    reporter:
        uncaughtErrorReporter ??
        feedbackReporter ??
        const NoopUncaughtErrorReporter(),
  );
  installBuildErrorView();

  // #10: deep-link reception. Source before the cubit's initialize (the
  // plugin buffers the cold-start launch link only if instantiated
  // early), after the hooks (handler faults are captured). The holder
  // exists on every platform — web's null source just means no handler
  // feeds it from out-of-band links; #83's auth-gate feeds it from the
  // router redirect instead.
  final pendingDeepLinkHolder = PendingDeepLinkHolder();
  final deepLinkSource = platformBootstrap.createDeepLinkSource();
  DeepLinkHandler? deepLinkHandler;
  if (deepLinkSource != null) {
    deepLinkHandler = DeepLinkHandler(
      source: deepLinkSource,
      holder: pendingDeepLinkHolder,
    )..start();
  }

  final bootstrapCubit = AppBootstrapCubit(
    platformBootstrap: platformBootstrap,
    hydratedStorageInitializer: hydratedStorageInitializer,
  );
  unawaited(bootstrapCubit.initialize());

  runApp(
    BgeApp(
      bootstrapCubit: bootstrapCubit,
      // runBgeApp has no teardown point of its own, so the app widget
      // owns the cubit's, the root container's, the deep-link handler's,
      // and the active-locale controller's lifecycles (relevant to hot
      // restart and tests).
      closeBootstrapCubitOnDispose: true,
      rootContainer: rootContainer,
      disposeRootContainerOnDispose: true,
      feedbackReporter: feedbackReporter,
      pendingDeepLinkHolder: pendingDeepLinkHolder,
      deepLinkHandler: deepLinkHandler,
      disposeDeepLinkHandlerOnDispose: true,
      activeLocaleController: activeLocaleController,
      disposeActiveLocaleControllerOnDispose: activeLocaleController != null,
      theme: theme,
      darkTheme: darkTheme,
      highContrastTheme: highContrastTheme,
      highContrastDarkTheme: highContrastDarkTheme,
      themeMode: themeMode,
      additionalLocalizationsDelegates: additionalLocalizationsDelegates,
    ),
  );
}
