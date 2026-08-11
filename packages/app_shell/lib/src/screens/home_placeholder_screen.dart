import 'package:auth/auth.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/shell_localizations.dart';
import '../router/app_router.dart';

/// Temporary authenticated landing surface (#37).
///
/// Exists only so the auth leg is verifiable end-to-end — it renders a
/// minimal confirmation and an accessible sign-out control wired to the
/// active server's [AuthBloc]. Replaced wholesale when the real home
/// (game collection, #114/#115) lands; intentionally minimal until then.
///
/// Also hosts the **temporary** "Send feedback" launcher (#107): the
/// permanent launcher placement is deferred until a real home/menu
/// surface exists, so this affordance doubles as the manual- and
/// widget-test host in the meantime and is removed with this screen. It
/// pushes [AppRoutes.feedback] (rather than `go`) so back returns here.
/// The label reuses the feedback feature's compose title — one string,
/// one translation. The **temporary** Settings launcher (#120) sits here
/// for the same reason and likewise pushes [AppRoutes.settings].
///
/// Must be built inside the scope-keyed [AuthBloc] provider (BgeApp's
/// home builder), so `context.read<AuthBloc>()` resolves the same
/// instance the gate used.
class HomePlaceholderScreen extends StatelessWidget {
  const HomePlaceholderScreen({super.key});

  /// Stable finder key for the temporary #107 launcher.
  static const Key sendFeedbackButtonKey = Key(
    'home_placeholder.send_feedback',
  );

  /// Stable finder key for the temporary #120 settings launcher.
  static const Key openSettingsButtonKey = Key(
    'home_placeholder.open_settings',
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    final feedbackL10n = FeedbackLocalizations.of(context);
    final shellL10n = ShellLocalizations.of(context);
    final theme = Theme.of(context);

    return BgePage(
      centerVertically: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const BgeGap.md(),
          Text(
            l10n.authSignInTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const BgeGap.lg(),
          Semantics(
            button: true,
            child: OutlinedButton.icon(
              key: HomePlaceholderScreen.sendFeedbackButtonKey,
              onPressed: () => context.push(AppRoutes.feedback),
              icon: const Icon(Icons.feedback_outlined),
              label: Text(feedbackL10n.feedbackComposeTitle),
            ),
          ),
          const BgeGap.sm(),
          Semantics(
            button: true,
            child: OutlinedButton.icon(
              key: HomePlaceholderScreen.openSettingsButtonKey,
              onPressed: () => context.push(AppRoutes.settings),
              icon: const Icon(Icons.settings_outlined),
              label: Text(shellL10n.settingsTitle),
            ),
          ),
          const BgeGap.sm(),
          Semantics(
            button: true,
            child: OutlinedButton.icon(
              onPressed: () =>
                  context.read<AuthBloc>().add(const AuthSignOutRequested()),
              icon: const Icon(Icons.logout),
              label: Text(l10n.authSignOutButton),
            ),
          ),
        ],
      ),
    );
  }
}
