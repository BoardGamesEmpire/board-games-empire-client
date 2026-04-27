import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:flutter/semantics.dart';

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Server attribution — important when user manages multiple servers
        Semantics(
          label: 'Server: ${widget.serverDisplayName}',
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
          _isSignIn ? 'Sign In' : 'Create Account',
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
            'or',
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
          'This server has no authentication methods configured. '
          'Please contact the server administrator.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  void _handleStateChange(BuildContext context, AuthBlocState state) {
    if (state is AuthFailure) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Semantics(liveRegion: true, child: Text(state.message)),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  void _switchMode({required bool signIn}) {
    setState(() => _isSignIn = signIn);
    // Announce mode change to screen readers
    SemanticsService.sendAnnouncement(
      View.of(context),
      signIn ? 'Switched to sign in form' : 'Switched to create account form',
      TextDirection.ltr,
    );
  }

  void _handleOidc(BuildContext context, OidcStrategy strategy) {
    // TODO(phase5): Launch OIDC redirect flow via platform-specific
    // browser integration. For now this is a placeholder.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('OIDC sign-in with ${strategy.providerId} — coming soon'),
      ),
    );
  }
}
