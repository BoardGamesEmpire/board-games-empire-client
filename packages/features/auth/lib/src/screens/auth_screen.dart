import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:flutter/semantics.dart';

import '../../l10n/auth_localizations.dart';
import '../bloc/auth_bloc.dart';
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
/// - Error messages shown in a live-region [SnackBar] for screen readers
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

    return BlocListener<AuthBloc, AuthBlocState>(
      listener: _handleStateChange,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                // Comfortable reading width on desktop/tablet
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(context, colorScheme),
                    const SizedBox(height: 32),
                    if (widget.identity.hasEmailAndPassword)
                      _buildEmailPasswordSection(context),
                    if (widget.identity.hasEmailAndPassword &&
                        widget.identity.hasOidc) ...[
                      const SizedBox(height: 24),
                      _buildDivider(context),
                      const SizedBox(height: 24),
                    ],
                    if (widget.identity.hasOidc) _buildOidcSection(context),
                    if (!widget.identity.hasEmailAndPassword &&
                        !widget.identity.hasOidc)
                      _buildNoStrategiesMessage(context),
                  ],
                ),
              ),
            ),
          ),
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
              const SizedBox(width: 6),
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
        const SizedBox(height: 12),
        Text(
          _isSignIn ? l10n.authSignInTitle : l10n.authRegisterTitle,
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
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
              const SizedBox(height: 12),
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
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
        padding: const EdgeInsets.all(16),
        child: Text(
          AuthLocalizations.of(context).authNoStrategiesMessage,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  void _handleStateChange(BuildContext context, AuthBlocState state) {
    if (state is AuthOperationFailure) {
      final message = _localizedFailure(AuthLocalizations.of(context), state);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Semantics(liveRegion: true, child: Text(message)),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
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
    final l10n = AuthLocalizations.of(context);
    setState(() => _isSignIn = signIn);
    // Announce mode change to screen readers
    SemanticsService.sendAnnouncement(
      View.of(context),
      signIn
          ? l10n.authSwitchedToSignInAnnouncement
          : l10n.authSwitchedToRegisterAnnouncement,
      Directionality.of(context),
    );
  }

  void _handleOidc(BuildContext context, OidcStrategy strategy) {
    // TODO(phase5): Launch OIDC redirect flow via platform-specific
    // browser integration. For now this is a placeholder.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AuthLocalizations.of(context).authOidcComingSoon(strategy.providerId),
        ),
      ),
    );
  }
}
