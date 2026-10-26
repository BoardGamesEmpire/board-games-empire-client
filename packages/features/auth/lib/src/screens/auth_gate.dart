import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
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
/// - [AuthSessionCheckFailed] → [SessionCheckFailedView] — the stored
///   session is indeterminate (offline / timeout / server error / a fault
///   on this device), never rejected, so showing the sign-in form would
///   wrongly suggest it is gone. The view's copy follows the failure's kind
///   (#396). Retry re-dispatches the session check; true offline-first
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
    this.unsentChangesCount,
  });

  /// The active server's identity — drives which strategies [AuthScreen]
  /// renders.
  final ServerIdentity identity;

  /// Human-readable server name, for attribution on the form and the
  /// session-check retry view.
  final String serverDisplayName;

  /// Rendered while the session check is unresolved (and for the redirect
  /// microtask after authentication). The shell passes its
  /// `SplashScreen` so cold start reads as one continuous splash.
  ///
  /// [AuthScreen] holds it too, while it reads [unsentChangesCount].
  final Widget splash;

  /// Passed to [AuthScreen.unsentChangesCount] (#142). Injected for the same
  /// reason as [splash]: the count lives in a per-server scope this feature
  /// doesn't reach into.
  final Future<int> Function()? unsentChangesCount;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthBlocState>(
      builder: (context, state) => switch (state) {
        AuthInitial() ||
        AuthSessionCheckInProgress() ||
        AuthAuthenticated() => splash,
        AuthSessionCheckFailed(:final kind) => SessionCheckFailedView(
          kind: kind,
          serverDisplayName: serverDisplayName,
          onRetry: () =>
              context.read<AuthBloc>().add(const AuthSessionCheckRequested()),
        ),
        AuthLoading() ||
        AuthUnauthenticated() ||
        AuthOperationFailure() => AuthScreen(
          identity: identity,
          serverDisplayName: serverDisplayName,
          unsentChangesCount: unsentChangesCount,
          splash: splash,
        ),
      },
    );
  }
}

/// Rendered when the startup session check could not complete (#37), saying
/// what failed (#396).
///
/// Title, body and icon all follow [kind], because "Can't reach the server"
/// is true of only one kind. Retry is the only action for every kind, a
/// locked keychain included: it unlocks, and anything else on offer would
/// throw the session away.
///
/// The layout and its accessibility (one live region for the failure, an
/// autofocused retry) come from [BgeErrorState], shared with the bootstrap
/// error screen (#102).
class SessionCheckFailedView extends StatelessWidget {
  const SessionCheckFailedView({
    super.key,
    required this.kind,
    required this.serverDisplayName,
    required this.onRetry,
  });

  final SessionCheckFailureKind kind;
  final String serverDisplayName;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    final (icon, title, body) = switch (kind) {
      SessionCheckFailureKind.unreachable => (
        Icons.cloud_off_outlined,
        l10n.authSessionUnreachableTitle(serverDisplayName),
        l10n.authSessionUnreachableBody,
      ),
      SessionCheckFailureKind.serverFault => (
        Icons.dns_outlined,
        l10n.authSessionServerFaultTitle(serverDisplayName),
        l10n.authSessionServerFaultBody,
      ),
      SessionCheckFailureKind.unexpected => (
        Icons.error_outline,
        l10n.authSessionUnexpectedTitle,
        l10n.authSessionUnexpectedBody,
      ),
    };

    return BgePage(
      centerVertically: true,
      child: BgeErrorState(
        icon: icon,
        title: title,
        body: body,
        retryLabel: l10n.authRetryButton,
        onRetry: onRetry,
      ),
    );
  }
}
