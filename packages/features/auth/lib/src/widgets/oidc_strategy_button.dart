import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/auth_localizations.dart';

/// Button representing a single OIDC authentication provider.
///
/// Accessibility: the [OutlinedButton] reports itself as one semantics node,
/// a button with its enabled state and the provider in its label, which
/// meets WCAG 2.1 SC 1.3.1 (Info and Relationships). A wrapper restating any
/// of that splits it into two nodes, and a screen reader announces the
/// provider twice (#188). The minimum touch target comes from
/// [BgeTokens.minTapTarget].
class OidcStrategyButton extends StatelessWidget {
  const OidcStrategyButton({
    super.key,
    required this.strategy,
    required this.onPressed,
    this.enabled = true,
  });

  final OidcStrategy strategy;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        minimumSize: Size(double.infinity, BgeTokens.of(context).minTapTarget),
      ),
      icon: const Icon(Icons.login, size: 20),
      label: Text(
        AuthLocalizations.of(context)
            .authContinueWith(_displayName(strategy.providerId)),
      ),
    );
  }

  /// Converts a raw provider ID into a display-friendly name.
  /// e.g. 'google-oidc' → 'Google Oidc', 'azure-ad' → 'Azure Ad'
  ///
  /// A fallback: the provider sign-in flow replaces it with the strategy's
  /// own display name (#583).
  String _displayName(String providerId) => providerId
      .split(RegExp(r'[-_]'))
      .map(
        (word) =>
            word.isEmpty ? word : word[0].toUpperCase() + word.substring(1),
      )
      .join(' ');
}
