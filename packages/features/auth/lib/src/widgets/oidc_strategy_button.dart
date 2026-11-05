import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/auth_localizations.dart';

/// Button representing a single OIDC authentication provider.
///
/// Four modes (#583):
/// - **At rest** it reads "Continue with" the provider's display name.
/// - **[busy]**: the sign-in it started is open in the browser. The label
///   says it is waiting for the provider, and a spinner takes the icon's
///   place.
/// - **[inert]**: another provider's sign-in is open. The label stays.
/// - **Disabled**: [unavailableOnDevice], whose label adds that the device
///   can't do it yet, or a null [onPressed], whose label stays. The screen
///   passes a null [onPressed] while an email sign-in or a sign-out runs.
///
/// Busy and inert are a [BgeInertButton]: still enabled, so the button keeps
/// focus, while a press does nothing. A screen-reader user back from the
/// browser lands on the button they pressed, where a disabled button would
/// have dropped them (#607). Neither answers a press or a hover. Inert is
/// drawn as a disabled button is, so a pointer user can see that a press will
/// do nothing; busy keeps its colours, because its label is what says why.
/// The disabled modes have no focus to keep, so they are disabled as before
/// (STYLE_GUIDE §5).
///
/// Accessibility: one semantics node, a button with its enabled state and the
/// visible label as its name, which meets WCAG 2.1 SC 1.3.1 (Info and
/// Relationships). A wrapper restating any of that splits it into two nodes,
/// and a screen reader announces the provider twice (#188). At rest, busy and
/// inert it is the same node, so a screen reader's cursor stays put as it
/// flips. The label wraps rather than clipping, so a long display name fits at
/// 320dp and 200% text. The minimum touch target comes from
/// [BgeTokens.minTapTarget].
class OidcStrategyButton extends StatelessWidget {
  const OidcStrategyButton({
    super.key,
    required this.strategy,
    required this.onPressed,
    this.busy = false,
    this.inert = false,
    this.unavailableOnDevice = false,
  });

  final OidcStrategy strategy;

  /// Starts a sign-in with [strategy]. Null disables the button, with its
  /// label at rest.
  final VoidCallback? onPressed;

  /// Whether this provider's sign-in is open in the browser.
  final bool busy;

  /// Whether another provider's sign-in is open, so a press must start
  /// nothing.
  final bool inert;

  /// Whether this device has no way to sign in through a provider. Disables
  /// the button, and its label says so (#583).
  final bool unavailableOnDevice;

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    final name = strategy.displayName;
    final press = onPressed;

    if (unavailableOnDevice || press == null) {
      return _OidcButton(
        label: unavailableOnDevice
            ? l10n.authContinueWithUnavailable(name)
            : l10n.authContinueWith(name),
        onPressed: null,
      );
    }

    final label = busy
        ? l10n.authContinueWithInProgress(name)
        : l10n.authContinueWith(name);
    final waiting = busy || inert;
    return BgeInertButton(
      inert: waiting,
      label: label,
      onPressed: press,
      builder: (context, focusNode, onPressed) => _OidcButton(
        label: label,
        focusNode: focusNode,
        onPressed: onPressed,
        busy: busy,
        waiting: waiting,
      ),
    );
  }
}

class _OidcButton extends StatelessWidget {
  const _OidcButton({
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.busy = false,
    this.waiting = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  /// Whether this button's own sign-in is open. Draws the spinner, and keeps
  /// the colours so the label stays legible.
  final bool busy;

  /// Whether a press does nothing now, though the button is enabled.
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      minimumSize: Size(double.infinity, BgeTokens.of(context).minTapTarget),
    );
    return OutlinedButton.icon(
      focusNode: focusNode,
      onPressed: onPressed,
      style: waiting
          ? _waitingStyle(context, muted: !busy).merge(style)
          : style,
      icon: busy ? const _BusySpinner() : const Icon(Icons.login, size: 20),
      // OutlinedButton.icon puts the label in a Flexible, so it wraps.
      label: Text(label),
    );
  }

  /// No answer to a press or a hover, as `BgeShelf`'s button at an end has
  /// none, and when [muted], drawn as a disabled button is. The focus overlay
  /// stays: it is how a keyboard user sees where they are.
  ButtonStyle _waitingStyle(BuildContext context, {required bool muted}) {
    final disabled = Theme.of(context).disabledColor;
    return ButtonStyle(
      foregroundColor: muted ? WidgetStatePropertyAll(disabled) : null,
      iconColor: muted ? WidgetStatePropertyAll(disabled) : null,
      side: muted ? WidgetStatePropertyAll(BorderSide(color: disabled)) : null,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? null
            : disabled.withValues(alpha: 0),
      ),
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.basic),
      splashFactory: NoSplash.splashFactory,
      enableFeedback: false,
    );
  }
}

/// The busy button's icon: a spinner scaled with the label beside it, in the
/// button's icon colour, and mute to a screen reader. The button's label is
/// what says it is waiting.
class _BusySpinner extends StatelessWidget {
  const _BusySpinner();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: BgeTextScale.clampedOf(context)
          .scale(BgeTokens.of(context).spaceMd),
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: IconTheme.of(context).color,
      ),
    ),
  );
}
