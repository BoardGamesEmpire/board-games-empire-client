import 'package:flutter/material.dart';
import 'package:models/domain.dart';

/// Button representing a single OIDC authentication provider.
///
/// Accessibility: uses [Semantics.button] with a descriptive label that
/// includes the provider name, meeting WCAG 2.1 SC 1.3.1 (Info and
/// Relationships). The minimum touch target is enforced via [minimumSize].
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
    final label = 'Continue with ${_displayName(strategy.providerId)}';

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 48),
        ),
        icon: const Icon(Icons.login, size: 20),
        label: Text(label),
      ),
    );
  }

  /// Converts a raw provider ID into a display-friendly name.
  /// e.g. 'google-oidc' → 'Google Oidc', 'azure-ad' → 'Azure Ad'
  String _displayName(String providerId) => providerId
      .split(RegExp(r'[-_]'))
      .map(
        (word) =>
            word.isEmpty ? word : word[0].toUpperCase() + word.substring(1),
      )
      .join(' ');
}
