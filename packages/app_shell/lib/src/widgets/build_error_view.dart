import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/shell_localizations.dart';
import '../../l10n/shell_localizations_en.dart';

/// Installs [BuildErrorView] as the process-global [ErrorWidget.builder]
/// (issue #66). Called by `runBgeApp` during bootstrap, alongside
/// `installGlobalErrorHooks` (#34). Idempotent by replacement — the
/// assignment never reads or chains the previous builder.
///
/// ## Why bootstrap, not `MaterialApp.builder`
///
/// The official Flutter sample assigns `ErrorWidget.builder` inside
/// `MaterialApp.builder` solely to capture a localized context. Two
/// reasons to deviate:
///
/// 1. [BuildErrorView] resolves its own localization at mount time (with
///    an English fallback), so no captured context is needed — the only
///    motivation for the in-widget placement is gone.
/// 2. `ErrorWidget.builder` is a process global that flutter_test's
///    `TestWidgetsFlutterBinding` verifies is restored at the end of every
///    `testWidgets` — a check that runs *before* `tearDown` callbacks.
///    A widget that mutates it during build therefore fails that
///    invariant in every test that pumps it. Installing from bootstrap
///    keeps widgets side-effect-free.
void installBuildErrorView() {
  ErrorWidget.builder = (details) => BuildErrorView(details: details);
}

/// Replaces Flutter's default in-build failure UI (issue #66) — the debug
/// red screen / release grey box — with a localized, screen-reader
/// friendly view. Installed process-globally by [installBuildErrorView]
/// from `runBgeApp`.
///
/// Capture of the underlying failure is #34's job
/// (`installGlobalErrorHooks`; `FlutterError.onError` fires for the same
/// error). This widget is presentation only — the capture/presentation
/// split across #34/#66 is deliberate.
///
/// ## Totality
///
/// This widget renders *inside an already-failing subtree*; a throw here
/// cascades into error-widget-inside-error-widget. Every lookup is
/// therefore fallible-safe, including with **zero ancestors** (a failure
/// at or above `MaterialApp`):
///
/// - The subtree is wrapped in a [Directionality] resolving the ambient
///   direction when present and falling back to LTR — [Text] hard-requires
///   one, and none exists above `MaterialApp`.
/// - Localization uses the nullable [Localizations.of] lookup with an
///   English fallback.
/// - [Theme.of] falls back to default (light) theme data with no theme
///   ancestor — a known cosmetic limitation for root-level failures:
///   there is no theme to read up there, and hand-rolled brightness
///   detection isn't worth the risk inside a must-be-total error path.
/// - The view supplies its own [Material] surface, so it renders correctly
///   whether it replaces a tile or a whole screen. (The official sample's
///   Scaffold-sniffing wrap is dead code under `MaterialApp.router`,
///   whose builder child is a `Router` — hence self-sufficiency instead.)
///
/// ## Layout & semantics (mirrors `BootstrapErrorScreen`)
///
/// Content is centered, width-capped at 480 (bounds text on desktop and
/// forces mid-word wrapping of unbreakable diagnostics tokens), and
/// scrollable so long diagnostics cannot overflow. The body text is a
/// merged live region so screen readers announce the failure when it
/// appears; the raw exception summary is excluded from semantics.
///
/// ## Diagnostics (decision 1a)
///
/// When [showDiagnostics] is true — defaulting to [kDebugMode] — the
/// exception summary is appended below the friendly message, preserving
/// the developer signal the stock red screen provided. Release builds
/// never show exception text; the raw detail still reaches the console
/// via `FlutterError.presentError` and the observability layer via #34.
class BuildErrorView extends StatelessWidget {
  /// Creates the view for a single build failure.
  const BuildErrorView({
    required this.details,
    this.showDiagnostics = kDebugMode,
    super.key,
  });

  /// The failure being presented. Only its [FlutterErrorDetails.exception]
  /// summary is ever shown, and only when diagnostics are on.
  final FlutterErrorDetails details;

  /// Whether to append the exception summary. Defaults to [kDebugMode].
  final bool showDiagnostics;

  @override
  Widget build(BuildContext context) {
    final localizations =
        Localizations.of<ShellLocalizations>(context, ShellLocalizations) ??
        ShellLocalizationsEn();
    final theme = Theme.of(context);

    return Directionality(
      // Text hard-requires a Directionality ancestor, which is absent for
      // failures at or above MaterialApp; honour the ambient direction
      // when one exists.
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Material(
        color: theme.colorScheme.surface,
        child: Center(
          // Center > SingleChildScrollView centers: the viewport sizes as
          // constraints.constrain(child.size), shrink-wrapping under
          // Center's loosened constraints. (The pin-to-top gotcha is the
          // inverted nesting.) Pinned by the geometry test.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Merged live region so screen readers announce the
                  // failure when it appears, without focus landing on it.
                  MergeSemantics(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        localizations.shellBuildErrorBody,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                  if (showDiagnostics) ...[
                    const SizedBox(height: 16),
                    // Developer signal only — excluded from semantics so
                    // screen readers get the friendly message, not a raw
                    // exception string.
                    ExcludeSemantics(
                      child: Text(
                        details.exceptionAsString(),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
