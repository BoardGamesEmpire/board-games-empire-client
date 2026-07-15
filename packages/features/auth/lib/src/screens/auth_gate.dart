import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';

import '../../l10n/auth_localizations.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_bloc_state.dart';
import 'auth_screen.dart';

/// The `/auth` route's state machine (#37): a pure function of
/// [AuthBloc] state with no widget-local memory.
///
/// - [AuthInitial] / [AuthSessionCheckInProgress] → [splash] (continuous
///   with the bootstrap splash; the session restore is in flight).
/// - [AuthAuthenticated] → [splash] — the shell's top-level listener has
///   already advanced the bootstrap cubit, so the router is about to
///   redirect to home; the gate holds splash for the intervening
///   microtask instead of flashing the form.
/// - [AuthSessionCheckFailed] → [SessionUnreachableView] — the stored
///   session is indeterminate (offline / timeout / server error), never
///   rejected, so showing the sign-in form would wrongly suggest it is
///   gone. Retry re-dispatches the session check; true offline-first
///   restore is #98.
/// - [AuthUnauthenticated] / [AuthLoading] / [AuthOperationFailure] →
///   [AuthScreen] — no session (or an interactive attempt in flight /
///   failed); the screen owns its own inline progress and live-region
///   error snack bar.
///
/// The splash is injected rather than imported: it lives in `app_shell`,
/// which depends on this feature — never the reverse.
class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.identity,
    required this.serverDisplayName,
    required this.splash,
  });

  /// The active server's identity — drives which strategies [AuthScreen]
  /// renders.
  final ServerIdentity identity;

  /// Human-readable server name, for attribution on the form and the
  /// unreachable view.
  final String serverDisplayName;

  /// Rendered while the session check is unresolved (and for the redirect
  /// microtask after authentication). The shell passes its
  /// `SplashScreen` so cold start reads as one continuous splash.
  final Widget splash;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthBlocState>(
      builder: (context, state) => switch (state) {
        AuthInitial() ||
        AuthSessionCheckInProgress() ||
        AuthAuthenticated() => splash,
        AuthSessionCheckFailed() => SessionUnreachableView(
          serverDisplayName: serverDisplayName,
          onRetry: () =>
              context.read<AuthBloc>().add(const AuthSessionCheckRequested()),
        ),
        AuthLoading() || AuthUnauthenticated() || AuthOperationFailure() =>
          AuthScreen(identity: identity, serverDisplayName: serverDisplayName),
      },
    );
  }
}

/// Rendered when the startup session check cannot reach the server (#37).
///
/// Accessibility (mirroring the bootstrap error screen's pattern):
/// - the title + body are a single live region so screen readers announce
///   the failure when it appears;
/// - the retry button is autofocused for keyboard users and carries an
///   explicit button semantic.
class SessionUnreachableView extends StatelessWidget {
  const SessionUnreachableView({
    super.key,
    required this.serverDisplayName,
    required this.onRetry,
  });

  final String serverDisplayName;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Column(
                      children: [
                        Text(
                          l10n.authSessionUnreachableTitle(serverDisplayName),
                          style: theme.textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.authSessionUnreachableBody,
                          style: theme.textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    button: true,
                    child: FilledButton(
                      autofocus: true,
                      onPressed: onRetry,
                      child: Text(l10n.authRetryButton),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
