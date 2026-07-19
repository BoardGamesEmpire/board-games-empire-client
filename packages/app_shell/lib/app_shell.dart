/// Shared application shell for Board Games Empire.
///
/// Owns the bootstrap sequence ([AppBootstrapCubit] over a platform-supplied
/// [PlatformBootstrap]), the `go_router` route table (including reserved
/// deep-link paths, #10), deep-link reception/normalization and the
/// pending-link slot (#10), global uncaught-error capture (#34) with the
/// "ask each time" crash-report flow (#69) and the full review/redaction
/// surface (#76), app-level i18n — the generated [ShellLocalizations] plus
/// the active-locale seam (#33) — and the shell screens (splash, bootstrap
/// failure, placeholders, not-yet-available).
///
/// Platform composition roots live in `packages/platform/*`; the apps under
/// `apps/*` are thin `main.dart` wrappers that hand a [PlatformBootstrap]
/// to [runBgeApp].
library;

export 'l10n/shell_localizations.dart';
export 'src/bootstrap/app_bootstrap_cubit.dart';
export 'src/bootstrap/app_bootstrap_state.dart';
export 'src/bootstrap/platform_bootstrap.dart';
export 'src/bootstrap/run_bge_app.dart';
export 'src/deep_links/deep_link_handler.dart';
export 'src/deep_links/deep_link_normalizer.dart';
export 'src/deep_links/deep_link_redaction.dart';
export 'src/deep_links/deep_link_source.dart';
export 'src/deep_links/known_server_lookup.dart';
export 'src/deep_links/pending_deep_link_holder.dart';
export 'src/i18n/active_locale.dart';
export 'src/observability/feedback_uncaught_error_reporter.dart';
export 'src/observability/global_error_hooks.dart';
export 'src/observability/shell_observability.dart';
export 'src/observability/uncaught_error_record.dart';
export 'src/router/app_router.dart';
export 'src/screens/bootstrap_error_screen.dart';
export 'src/screens/feedback_flow_screen.dart';
export 'src/screens/home_placeholder_screen.dart';
export 'src/screens/not_yet_available_screen.dart';
export 'src/screens/shell_placeholder_screen.dart';
export 'src/screens/splash_screen.dart';
export 'src/widgets/bge_app.dart';
export 'src/widgets/build_error_view.dart';
export 'src/widgets/crash_report_prompt.dart';
export 'src/widgets/feedback_review_screen.dart';
export 'src/widgets/router_back_interceptor.dart';
