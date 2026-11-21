import 'package:flutter/material.dart';
import 'package:server_onboarding/l10n/server_onboarding_localizations.dart';
import 'package:server_onboarding/src/widgets/server_add_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The add-server screen: at first run (#36), and from the server manager
/// (#134). Expects a `ServerOnboardingBloc` to be provided above it (the
/// shell's router wiring owns bloc construction and success handling).
class ServerAddScreen extends StatelessWidget {
  const ServerAddScreen({this.title, this.initialAddress, super.key});

  /// The app bar's title, for a screen opened over another page, which the
  /// app bar's Back returns to. The app bar's title is then the page's
  /// heading, and the body has none of its own, so the name is read once.
  ///
  /// Null at first run, where there is nothing to go back to: no app bar,
  /// and the body carries the heading.
  final Widget? title;

  /// An address to start the form's address field with, such as the one a
  /// link carries (#971).
  final String? initialAddress;

  @override
  Widget build(BuildContext context) {
    final l10n = ServerOnboardingLocalizations.of(context);

    return BgePage(
      title: title,
      centerVertically: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title == null) ...[
            Semantics(
              header: true,
              child: Text(
                l10n.serverAddTitle,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const BgeGap.sm(),
          ],
          Text(
            l10n.serverAddIntro,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const BgeGap.lg(),
          ServerAddForm(initialAddress: initialAddress),
        ],
      ),
    );
  }
}
