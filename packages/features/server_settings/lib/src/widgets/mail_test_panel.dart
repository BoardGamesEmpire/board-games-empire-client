import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/bloc/mail_test_state.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Send test email, and what became of the last test (#807).
///
/// The test goes through the **saved** settings, so the button is disabled,
/// with its reason under it, while the Mail group has unsaved changes or no
/// host and From address are saved. Unsaved changes win: saving them is the
/// next step either way. The reason is also the button's hint, so a screen
/// reader hears it with the button, and the drawn line is left out of the
/// semantics tree so it isn't read twice.
///
/// While a test is out the button holds its focus and ignores presses
/// ([BgeInertButton]): the press that sent it is what made it unavailable.
///
/// Sending is a direct write, so offline the button is disabled and carries
/// the reason as its hint. The note is drawn once for the whole group, by the
/// form that hosts this panel.
///
/// The outcome is a banner under the button, keyed by the attempt it answers,
/// so the same outcome twice in a row is announced twice. When it may answer
/// an earlier test that ran out of time, the banner says so.
class MailTestPanel extends StatelessWidget {
  const MailTestPanel({
    required this.state,
    required this.hasUnsavedChanges,
    required this.mailConfigured,
    required this.onSend,
    super.key,
  });

  static const Key sendKey = Key('mail_test_panel.send');

  final MailTestState state;

  /// Whether the Mail group has changes that aren't saved.
  final bool hasUnsavedChanges;

  /// Whether the saved settings have a host and a From address.
  final bool mailConfigured;

  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);
    final theme = Theme.of(context);
    final state = this.state;
    final reason = hasUnsavedChanges
        ? l10n.mailTestUnsaved
        : mailConfigured
        ? null
        : l10n.mailTestNotConfigured;
    final offline = BgeConnectivityScope.offlineOf(context);
    final outcome = _outcome(l10n, state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BgeOnlineOnly(
          showNote: false,
          // Merged into the button's node by the wrapper above it, so the
          // reason is read with the button.
          child: Semantics(
            hint: reason,
            child: BgeInertButton(
              inert: state is MailTestSending || state is MailTestWaiting,
              label: l10n.mailTestSend,
              onPressed: reason != null || offline ? null : onSend,
              builder: (context, focusNode, onPressed) => OutlinedButton(
                key: sendKey,
                focusNode: focusNode,
                onPressed: onPressed,
                child: Text(l10n.mailTestSend),
              ),
            ),
          ),
        ),
        if (reason != null) ...[
          const BgeGap.xs(),
          ExcludeSemantics(
            child: Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        if (outcome != null) ...[
          const BgeGap.md(),
          BgeInlineBanner(
            key: ValueKey(state.attempt),
            tone: outcome.tone,
            title: outcome.title,
            message: state is MailTestOutcome && state.mayAnswerEarlierTest
                ? l10n.mailTestMayAnswerEarlier(outcome.message)
                : outcome.message,
          ),
        ],
      ],
    );
  }

  /// A failure is titled: some of its messages state only a cause, such as
  /// "Mail isn't set up yet.", and the title says the test failed.
  static ({BgeBannerTone tone, String? title, String message})? _outcome(
    ServerSettingsLocalizations l10n,
    MailTestState state,
  ) => switch (state) {
    MailTestIdle() || MailTestSending() => null,
    MailTestWaiting() => (
      tone: BgeBannerTone.info,
      title: null,
      message: l10n.mailTestWaiting,
    ),
    MailTestOutcome(:final result) when result.sent => (
      tone: BgeBannerTone.success,
      title: null,
      message: l10n.mailTestSent,
    ),
    MailTestOutcome(:final result) => (
      tone: BgeBannerTone.error,
      title: l10n.mailTestFailedTitle,
      message: _failure(l10n, result),
    ),
    MailTestNoResult() => (
      tone: BgeBannerTone.warning,
      title: null,
      message: l10n.mailTestNoResult,
    ),
    MailTestNotSent(:final reason) => (
      tone: BgeBannerTone.error,
      title: l10n.mailTestNotSentTitle,
      message: switch (reason) {
        MailTestNotSentReason.notConfigured =>
          l10n.mailTestNotSentNotConfigured,
        MailTestNotSentReason.queueUnavailable =>
          l10n.mailTestNotSentQueueUnavailable,
        MailTestNotSentReason.refused => l10n.mailTestNotSentRefused,
        MailTestNotSentReason.failed => l10n.mailTestNotSentFailed,
      },
    ),
  };

  /// Told by the failure's code. A code this app doesn't know shows the
  /// server's own words, the one place they are shown (#807), or with none,
  /// the general failure, so the banner never has an empty body.
  static String _failure(
    ServerSettingsLocalizations l10n,
    MailTestResult result,
  ) => switch (result.failure) {
    MailFailure.notConfigured => l10n.mailTestFailedNotConfigured,
    MailFailure.settingsUnreadable => l10n.mailTestFailedSettingsUnreadable,
    MailFailure.authFailed => l10n.mailTestFailedAuthFailed,
    MailFailure.hostUnreachable => l10n.mailTestFailedHostUnreachable,
    MailFailure.tlsFailed => l10n.mailTestFailedTlsFailed,
    MailFailure.rejected => l10n.mailTestFailedRejected,
    MailFailure.sendFailed => l10n.mailTestFailedSendFailed,
    MailFailure.unknown || null =>
      result.message.trim().isEmpty
          ? l10n.mailTestFailedSendFailed
          : result.message,
  };
}
