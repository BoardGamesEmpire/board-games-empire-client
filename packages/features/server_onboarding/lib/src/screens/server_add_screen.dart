import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/server_onboarding_localizations.dart';
import '../widgets/server_add_form.dart';

/// First-run add-server screen (#36). Expects a `ServerOnboardingBloc`
/// to be provided above it (the shell's router wiring owns bloc
/// construction and success handling).
class ServerAddScreen extends StatelessWidget {
  const ServerAddScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = ServerOnboardingLocalizations.of(context);

    return BgePage(
      centerVertically: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.serverAddTitle,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          const BgeGap.sm(),
          Text(
            l10n.serverAddIntro,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const BgeGap.lg(),
          const ServerAddForm(),
        ],
      ),
    );
  }
}
