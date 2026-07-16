import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Temporary authenticated landing surface (#37).
///
/// Exists only so the auth leg is verifiable end-to-end — it renders a
/// minimal confirmation and an accessible sign-out control wired to the
/// active server's [AuthBloc]. Replaced wholesale when the real home
/// (game collection, #114/#115) lands; intentionally minimal until then.
///
/// Must be built inside the scope-keyed [AuthBloc] provider (BgeApp's
/// home builder), so `context.read<AuthBloc>()` resolves the same
/// instance the gate used.
class HomePlaceholderScreen extends StatelessWidget {
  const HomePlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.authSignInTitle,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    button: true,
                    child: OutlinedButton.icon(
                      onPressed: () => context.read<AuthBloc>().add(
                        const AuthSignOutRequested(),
                      ),
                      icon: const Icon(Icons.logout),
                      label: Text(l10n.authSignOutButton),
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
