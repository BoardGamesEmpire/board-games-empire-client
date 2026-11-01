import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

/// Why a DataGateway's last interview failed, as a phrase that follows a
/// colon: "Not in use: it didn't answer" (#457).
///
/// The server sends a coarse code and keeps the raw error in its own log, so
/// this is all that can be said. A code this client does not know has already
/// become [DataGatewayInterviewFailureCode.unknown] by the time it gets here.
///
/// A function rather than a widget's private detail because every screen that
/// reports a failed interview says its reason in these words.
String dataGatewayInterviewFailureLabel(
  DataGatewayLocalizations l10n,
  DataGatewayInterviewFailureCode code,
) => switch (code) {
  DataGatewayInterviewFailureCode.pingFailed =>
    l10n.dataGatewayInterviewFailurePingFailed,
  DataGatewayInterviewFailureCode.describeUnsupported =>
    l10n.dataGatewayInterviewFailureDescribeUnsupported,
  DataGatewayInterviewFailureCode.describeFailed =>
    l10n.dataGatewayInterviewFailureDescribeFailed,
  DataGatewayInterviewFailureCode.unknown =>
    l10n.dataGatewayInterviewFailureUnknown,
};

/// Whether the server uses an enabled DataGateway yet, and if not, why not
/// (#457): an icon and words, never color alone.
///
/// The server does not use a DataGateway until one interview has succeeded,
/// so an enabled one that no interview has succeeded for is enabled and
/// returns nothing. One whose later interview failed is still in use, on what
/// the earlier interview found. Read from the row's `interview` block as it
/// comes: the server has already decided which failure is current, so nothing
/// here compares timestamps.
///
/// | Interviewed | Failure | Line |
/// |---|---|---|
/// | no | none | Not in use yet: waiting for its first interview |
/// | no | one | Not in use: the reason |
/// | yes | one | Last interview failed: the reason |
/// | yes | none | In use |
///
/// Builds nothing for a disabled DataGateway. The server does not use it
/// whatever its interviews say, and [DataGatewayEnabledBadge] already says so.
class DataGatewayStatusLine extends StatelessWidget {
  const DataGatewayStatusLine({required this.gateway, super.key});

  final DataGateway gateway;

  @override
  Widget build(BuildContext context) {
    if (!gateway.enabled) return const SizedBox.shrink();

    final l10n = DataGatewayLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final interview = gateway.interview;
    final failure = interview.failure;
    final reason = failure == null
        ? null
        : dataGatewayInterviewFailureLabel(l10n, failure.code);

    // The colors are the ones `BgeInlineBanner` gives the same meanings:
    // ember for what is still to come or only partly wrong, crimson for what
    // has failed outright.
    final (icon, color, words) = switch ((interview.interviewed, reason)) {
      (false, null) => (
        Icons.hourglass_empty,
        scheme.tertiary,
        l10n.dataGatewayStatusWaiting,
      ),
      (false, final reason?) => (
        Icons.error_outline,
        scheme.error,
        l10n.dataGatewayStatusNotInUse(reason),
      ),
      (true, final reason?) => (
        Icons.warning_amber,
        scheme.tertiary,
        l10n.dataGatewayStatusLastFailed(reason),
      ),
      (true, null) => (
        Icons.check_circle_outline,
        scheme.primary,
        l10n.dataGatewayStatusInUse,
      ),
    };

    return _IconAndWords(icon: icon, color: color, words: words);
  }
}

/// "Enabled" or "Disabled", as an icon plus words, never color alone.
///
/// Whether an admin has switched the DataGateway on, which is all the server
/// stores about its connection (#41). Whether the server is using it yet is
/// [DataGatewayStatusLine]'s to say.
class DataGatewayEnabledBadge extends StatelessWidget {
  const DataGatewayEnabledBadge({required this.enabled, super.key});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return _IconAndWords(
      icon: enabled
          ? Icons.check_circle_outline
          : Icons.do_not_disturb_on_outlined,
      color: enabled ? scheme.primary : scheme.onSurfaceVariant,
      words: enabled ? l10n.dataGatewayEnabled : l10n.dataGatewayDisabled,
    );
  }
}

/// An icon beside words in one color: the shape of every status this feature
/// shows, so the words are never left to the color to carry.
class _IconAndWords extends StatelessWidget {
  const _IconAndWords({
    required this.icon,
    required this.color,
    required this.words,
  });

  final IconData icon;
  final Color color;
  final String words;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          // Scales with its label, like the household badge.
          size: MediaQuery.textScalerOf(context)
              .scale(theme.textTheme.labelMedium?.fontSize ?? 0),
          color: color,
        ),
        const BgeGap.xs(axis: Axis.horizontal),
        // Flexible, so a long line wraps inside the row at 200% text rather
        // than running off it.
        Flexible(
          child: Text(
            words,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
