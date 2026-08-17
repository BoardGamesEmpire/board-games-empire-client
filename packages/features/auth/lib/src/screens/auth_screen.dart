import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';

import '../../l10n/auth_localizations.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_bloc_state.dart';
import '../widgets/login_form.dart';
import '../widgets/register_form.dart';
import '../widgets/oidc_strategy_button.dart';

/// Top-level authentication screen.
///
/// Strategy-aware: renders exactly the forms and buttons that the server
/// advertises via [identity]. If the server disables registration,
/// the registration form and toggle link are suppressed.
///
/// Accessibility:
/// - Operation failures surface in a [BgeInlineBanner], which announces
///   itself on appearance. The screen stays put through a failure, so the
///   message belongs on it rather than in a SnackBar (#191).
/// - Focus is managed between sign-in/register mode switches
/// - Server name displayed so screen readers can identify which server
///   the user is authenticating against
///
/// i18n (#37): all copy comes from [AuthLocalizations]; the bloc emits
/// semantic failure kinds ([AuthOperationFailure]) which
/// [_localizedFailure] maps to localized messages here — never in the
/// bloc.
///
/// Callers are responsible for navigating away when the bloc emits
/// [AuthAuthenticated] — typically via a [BlocListener] in the router.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.identity,
    required this.serverDisplayName,
  });

  /// Key on the operation-failure banner, for tests.
  static const Key failureBannerKey = Key('auth_failure_banner');

  /// The server identity for this auth context. Drives which strategies
  /// are shown and which endpoints are used.
  final ServerIdentity identity;

  /// Human-readable server name shown above the form for context.
  final String serverDisplayName;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  /// Whether the user is in sign-in or register mode.
  /// Only relevant when [EmailAndPasswordStrategy.signUpDisabled] is false.
  bool _isSignIn = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Scoped to the failure surface: the OIDC section and both forms hold
    // their own narrower builders, and an unscoped rebuild here would make
    // those pointless by rebuilding the whole page on every tick.
    return BlocBuilder<AuthBloc, AuthBlocState>(
      buildWhen: (previous, current) =>
          previous is AuthOperationFailure || current is AuthOperationFailure,
      builder: (context, state) => BgePage(
        centerVertically: true,
        // Wider vertical breathing room than the default: this is the first
        // screen after server-add and carries no app bar, so the form would
        // otherwise sit hard against the status bar.
        padding: EdgeInsets.symmetric(
          horizontal: BgeTokens.of(context).spaceLg,
          vertical: BgeTokens.of(context).spaceXl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, colorScheme),
            const BgeGap.xl(),
            if (state case final AuthOperationFailure failure) ...[
              BgeInlineBanner(
                key: AuthScreen.failureBannerKey,
                tone: BgeBannerTone.error,
                message: _localizedFailure(
                  AuthLocalizations.of(context),
                  failure,
                ),
              ),
              const BgeGap.md(),
            ],
            if (widget.identity.hasEmailAndPassword)
              _buildEmailPasswordSection(context),
            if (widget.identity.hasEmailAndPassword &&
                widget.identity.hasOidc) ...[
              const BgeGap.lg(),
              _buildDivider(context),
              const BgeGap.lg(),
            ],
            if (widget.identity.hasOidc) _buildOidcSection(context),
            if (!widget.identity.hasEmailAndPassword &&
                !widget.identity.hasOidc)
              _buildNoStrategiesMessage(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme colorScheme) {
    final l10n = AuthLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Server attribution — important when user manages multiple servers
        Semantics(
          label: '${l10n.authServerLabel}: ${widget.serverDisplayName}',
          child: Row(
            children: [
              Icon(
                Icons.dns_outlined,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const BgeGap.xs(axis: Axis.horizontal),
              Flexible(
                child: Text(
                  widget.serverDisplayName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const BgeGap.sm(),
        // A live region rather than a `SemanticsService` announcement: this
        // heading IS the thing that changes when the user switches modes, so
        // the change announces itself. Android deprecated announcement events
        // because they clear TalkBack's speech queue mid-utterance — the
        // style guide's standing rule, which the old `_switchMode` call
        // predated.
        Semantics(
          liveRegion: true,
          child: Text(
            _isSignIn ? l10n.authSignInTitle : l10n.authRegisterTitle,
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildEmailPasswordSection(BuildContext context) {
    final strategy = widget.identity.emailAndPasswordStrategy!;
    final canRegister = !strategy.signUpDisabled;

    if (_isSignIn) {
      return LoginForm(
        onSwitchToRegister: canRegister
            ? () => _switchMode(signIn: false)
            : null,
      );
    } else {
      return RegisterForm(onSwitchToSignIn: () => _switchMode(signIn: true));
    }
  }

  Widget _buildOidcSection(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthBlocState>(
      builder: (context, state) {
        final isLoading = state is AuthLoading;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final oidcStrategy in widget.identity.oidcStrategies) ...[
              OidcStrategyButton(
                strategy: oidcStrategy,
                enabled: !isLoading,
                onPressed: () => _handleOidc(context, oidcStrategy),
              ),
              const BgeGap.sm(),
            ],
          ],
        );
      },
    );
  }

  Widget _buildDivider(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: BgeTokens.of(context).spaceMd,
          ),
          child: Text(
            AuthLocalizations.of(context).authOrDivider,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }

  Widget _buildNoStrategiesMessage(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: EdgeInsets.all(BgeTokens.of(context).spaceMd),
        child: Text(
          AuthLocalizations.of(context).authNoStrategiesMessage,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// The single place the sealed failure kinds become user-facing copy.
  /// Exhaustive: a new kind fails compilation here until it gets a
  /// localized message.
  String _localizedFailure(AuthLocalizations l10n, AuthOperationFailure f) =>
      switch (f) {
        AuthFailureInvalidCredentials() => l10n.authErrorInvalidCredentials,
        AuthFailureEmailAlreadyExists() => l10n.authErrorEmailExists,
        AuthFailureRegistrationDisabled() => l10n.authRegistrationDisabled,
        AuthFailureNetwork() => l10n.authErrorNetwork,
        AuthFailureServer() => l10n.authErrorServer,
      };

  void _switchMode({required bool signIn}) {
    // Retire any failure first: it describes a submission to the form the
    // user is leaving, so carrying it over would pin a credentials
    // complaint above the registration form. The banner is bound to bloc
    // state and does not fade the way the SnackBar it replaced did (#191).
    context.read<AuthBloc>().add(const AuthFailureCleared());
    // The heading is a live region, so changing it announces the new mode.
    setState(() => _isSignIn = signIn);
  }

  void _handleOidc(BuildContext context, OidcStrategy strategy) {
    // TODO(phase5): Launch OIDC redirect flow via platform-specific
    // browser integration. For now this is a placeholder.
    //
    // A SnackBar rather than a BgeInlineBanner, and deliberately: this is a
    // transient "not built yet" notice, not the outcome of a form the user
    // submitted, and it disappears with this placeholder. Note it carries no
    // `Semantics(liveRegion:)` wrapper — SnackBar already is one
    // (`snack_bar.dart`), and nesting the two makes screen readers stutter
    // (#191).
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AuthLocalizations.of(context).authOidcComingSoon(strategy.providerId),
        ),
      ),
    );
  }
}
