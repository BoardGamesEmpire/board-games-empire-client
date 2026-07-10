import 'package:flutter/material.dart';
import 'package:observability/observability.dart';

import '../../l10n/shell_localizations.dart';

/// Minimal accessible "ask each time" crash prompt (#69).
///
/// Deliberately small — crash summary, optional comment, send/discard —
/// with an **honest outcome**: "sent" vs "saved to send later"
/// ([FeedbackSubmitResult]), because on web "saved" only lasts until
/// reload. The full review/redaction surface
/// (`FeedbackReportPreview`-driven) is #76.
///
/// Dumb by design: takes the pre-built draft (capture-time breadcrumbs —
/// see `FeedbackUncaughtErrorReporter`) and callbacks; the shell wiring
/// in `BgeApp` owns clearing the RAM slots. Self-contained in a
/// [Material] so it renders correctly when overlaid above the router's
/// navigator (no Scaffold ancestor there).
///
/// Nothing is sent without tapping send — the #34 privacy contract's
/// user-facing edge.
class CrashReportPrompt extends StatefulWidget {
  const CrashReportPrompt({
    required this.report,
    required this.onSubmit,
    required this.onDiscard,
    super.key,
  });

  /// The capture-time draft, before the user's comment.
  final FeedbackReport report;

  /// Submits the (comment-woven) report; the result drives the outcome
  /// state shown to the user.
  final Future<FeedbackSubmitResult> Function(FeedbackReport report) onSubmit;

  /// The user declined (or dismissed an outcome state); the caller
  /// clears the RAM slots.
  final VoidCallback onDiscard;

  /// Stable finder keys — tests use these so they hold across locales.
  static const Key commentFieldKey = Key('crash_report_prompt.comment');
  static const Key sendButtonKey = Key('crash_report_prompt.send');
  static const Key discardButtonKey = Key('crash_report_prompt.discard');
  static const Key sentConfirmationKey = Key('crash_report_prompt.sent');
  static const Key queuedConfirmationKey = Key('crash_report_prompt.queued');
  static const Key submissionFailedKey = Key('crash_report_prompt.failed');

  @override
  State<CrashReportPrompt> createState() => _CrashReportPromptState();
}

enum _PromptPhase { composing, sending, sent, queued, failed }

class _CrashReportPromptState extends State<CrashReportPrompt> {
  final TextEditingController _comment = TextEditingController();
  _PromptPhase _phase = _PromptPhase.composing;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _phase = _PromptPhase.sending);
    try {
      final result = await widget.onSubmit(
        widget.report.withUserComment(_comment.text),
      );
      if (!mounted) return;
      setState(
        () => _phase = result == FeedbackSubmitResult.sent
            ? _PromptPhase.sent
            : _PromptPhase.queued,
      );
    } on Object {
      if (!mounted) return;
      setState(() => _phase = _PromptPhase.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final theme = Theme.of(context);

    return SafeArea(
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: switch (_phase) {
              _PromptPhase.composing ||
              _PromptPhase.sending => _composing(l10n),
              _PromptPhase.sent => _outcome(
                l10n,
                key: CrashReportPrompt.sentConfirmationKey,
                icon: Icons.check_circle_outline,
                text: l10n.crashReportPromptSent,
              ),
              _PromptPhase.queued => _outcome(
                l10n,
                key: CrashReportPrompt.queuedConfirmationKey,
                icon: Icons.schedule_send_outlined,
                text: l10n.crashReportPromptQueued,
              ),
              _PromptPhase.failed => _outcome(
                l10n,
                key: CrashReportPrompt.submissionFailedKey,
                icon: Icons.error_outline,
                text: l10n.crashReportPromptFailed,
              ),
            },
          ),
        ),
      ),
    );
  }

  Widget _composing(ShellLocalizations l10n) {
    final sending = _phase == _PromptPhase.sending;
    final title = widget.report.title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.crashReportPromptTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(l10n.crashReportPromptExplanation),
        const SizedBox(height: 12),
        if (title != null && title.isNotEmpty)
          Text(title, style: Theme.of(context).textTheme.labelLarge),
        Text(
          widget.report.message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 12),
        TextField(
          key: CrashReportPrompt.commentFieldKey,
          controller: _comment,
          enabled: !sending,
          maxLines: 3,
          minLines: 1,
          decoration: InputDecoration(
            labelText: l10n.crashReportPromptCommentLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          spacing: 8,
          children: [
            TextButton(
              key: CrashReportPrompt.discardButtonKey,
              onPressed: sending ? null : widget.onDiscard,
              child: Text(l10n.crashReportPromptDiscard),
            ),
            FilledButton(
              key: CrashReportPrompt.sendButtonKey,
              onPressed: sending ? null : _send,
              child: Text(l10n.crashReportPromptSend),
            ),
          ],
        ),
      ],
    );
  }

  /// Terminal outcome states: an announced status line plus a dismiss
  /// affordance. The dismiss button reuses [CrashReportPrompt.discardButtonKey]
  /// deliberately — in every phase, that key is "the button that closes
  /// the prompt without (further) sending".
  Widget _outcome(
    ShellLocalizations l10n, {
    required Key key,
    required IconData icon,
    required String text,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Row(
            key: key,
            children: [
              Icon(icon),
              const SizedBox(width: 8),
              Expanded(child: Text(text)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: CrashReportPrompt.discardButtonKey,
            onPressed: widget.onDiscard,
            child: Text(l10n.crashReportPromptDismiss),
          ),
        ),
      ],
    );
  }
}
