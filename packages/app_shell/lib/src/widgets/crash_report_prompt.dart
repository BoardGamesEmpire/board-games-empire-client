import 'package:flutter/material.dart';
import 'package:observability/observability.dart';

import '../../l10n/shell_localizations.dart';

/// Minimal accessible "ask each time" crash prompt (#69).
///
/// Deliberately small — crash summary, optional comment, send/discard —
/// with an **honest outcome**: "sent" vs "saved to send later"
/// ([FeedbackSubmitResult]), because on web "saved" only lasts until
/// reload.
///
/// The full review/redaction surface ([FeedbackReportPreview]-driven) is
/// #76: when [onReviewDetails] is supplied, a "Review details" affordance
/// appears alongside send/discard and hands the currently-typed comment up
/// so the host can build the review preview from
/// `draft.withUserComment(comment)`. The prompt itself stays dumb — it
/// owns no review UI, only the callback.
///
/// System back (#106): the prompt owns no back handling either — the host
/// intercepts back at the router's dispatcher and flips [showDismissHint]
/// after a first intercepted press. The prompt merely renders the
/// localized hint in a live region (announced by assistive tech, visible
/// to sighted users) so the "press back again to dismiss" affordance is
/// discoverable by both audiences.
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
    this.onReviewDetails,
    this.showDismissHint = false,
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

  /// Opens the full review & redaction surface (#76), carrying the
  /// currently-typed comment so the host can weave it into the message
  /// before building the preview. Optional: when null (e.g. #69-only
  /// tests) the "Review details" affordance is not shown and the prompt
  /// behaves exactly as it did before #76.
  final void Function(String comment)? onReviewDetails;

  /// Whether to render the back-dismiss hint (#106): the host sets this
  /// after intercepting a first system back, while a second back within
  /// its window would discard. Rendered in a live region so the
  /// affordance is announced non-visually. Default false — hosts without
  /// back interception (and pre-#106 tests) are unchanged.
  final bool showDismissHint;

  /// Stable finder keys — tests use these so they hold across locales.
  static const Key commentFieldKey = Key('crash_report_prompt.comment');
  static const Key sendButtonKey = Key('crash_report_prompt.send');
  static const Key discardButtonKey = Key('crash_report_prompt.discard');
  static const Key reviewButtonKey = Key('crash_report_prompt.review');
  static const Key dismissHintKey = Key(
    'crash_report_prompt.back_dismiss_hint',
  );
  static const Key sentConfirmationKey = Key('crash_report_prompt.sent');
  static const Key queuedConfirmationKey = Key('crash_report_prompt.queued');
  static const Key submissionFailedKey = Key('crash_report_prompt.failed');
  static const Key submissionRejectedKey = Key('crash_report_prompt.rejected');

  @override
  State<CrashReportPrompt> createState() => _CrashReportPromptState();
}

enum _PromptPhase { composing, sending, sent, queued, rejected, failed }

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
    } on FeedbackPermanentSubmissionException catch (error) {
      // #97: permanent rejection — deliberately NOT queued ("saved for
      // later" would be a lie). The rejected copy attributes the
      // decision to the server, so it may only render when the server
      // actually made one: a null statusCode means the rejection never
      // left the client (submit's validation gate), and the generic
      // failed copy — "couldn't be sent or saved", both true — is the
      // honest one there.
      if (!mounted) return;
      setState(
        () => _phase = error.statusCode != null
            ? _PromptPhase.rejected
            : _PromptPhase.failed,
      );
    } on Object {
      if (!mounted) return;
      setState(() => _phase = _PromptPhase.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
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
              _PromptPhase.sending => _composing(i18n),
              _PromptPhase.sent => _outcome(
                i18n,
                key: CrashReportPrompt.sentConfirmationKey,
                icon: Icons.check_circle_outline,
                text: i18n.crashReportPromptSent,
              ),
              _PromptPhase.queued => _outcome(
                i18n,
                key: CrashReportPrompt.queuedConfirmationKey,
                icon: Icons.schedule_send_outlined,
                text: i18n.crashReportPromptQueued,
              ),
              _PromptPhase.rejected => _outcome(
                i18n,
                key: CrashReportPrompt.submissionRejectedKey,
                icon: Icons.block_outlined,
                text: i18n.crashReportPromptRejected,
              ),
              _PromptPhase.failed => _outcome(
                i18n,
                key: CrashReportPrompt.submissionFailedKey,
                icon: Icons.error_outline,
                text: i18n.crashReportPromptFailed,
              ),
            },
          ),
        ),
      ),
    );
  }

  Widget _composing(ShellLocalizations i18n) {
    final sending = _phase == _PromptPhase.sending;
    final title = widget.report.title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.crashReportPromptTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(i18n.crashReportPromptExplanation),
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
            labelText: i18n.crashReportPromptCommentLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        // #106: the back-dismiss hint, host-driven. A live region so the
        // "press back again" affordance is announced when it appears.
        if (widget.showDismissHint) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              i18n.crashReportPromptBackDismissHint,
              key: CrashReportPrompt.dismissHintKey,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        const SizedBox(height: 12),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          spacing: 8,
          children: [
            TextButton(
              key: CrashReportPrompt.discardButtonKey,
              onPressed: sending ? null : widget.onDiscard,
              child: Text(i18n.crashReportPromptDiscard),
            ),
            // #76: only when the host wired a review handler. Passes the
            // current comment so it is woven into the message the review
            // surface shows (and ultimately submits).
            if (widget.onReviewDetails != null)
              TextButton(
                key: CrashReportPrompt.reviewButtonKey,
                onPressed: sending
                    ? null
                    : () => widget.onReviewDetails!(_comment.text),
                child: Text(i18n.crashReportPromptReview),
              ),
            FilledButton(
              key: CrashReportPrompt.sendButtonKey,
              onPressed: sending ? null : _send,
              child: Text(i18n.crashReportPromptSend),
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
    ShellLocalizations i18n, {
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
            child: Text(i18n.crashReportPromptDismiss),
          ),
        ),
      ],
    );
  }
}
