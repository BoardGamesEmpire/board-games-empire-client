import 'package:flutter/material.dart';
import 'package:observability/observability.dart';

import '../../l10n/shell_localizations.dart';

/// Full feedback-report review & redaction surface (#76).
///
/// Split from #69 (which ships the minimal crash prompt): this is the
/// complete "what would leave the device" surface. It renders the composed
/// message, the app environment, the redactable `deviceInfo` entries, and
/// the view-only diagnostics (stack trace, breadcrumb trail), and lets the
/// user toggle per-field redaction before anything is submitted.
///
/// ## Redaction is entirely model-driven
///
/// The widget owns no redaction logic. It holds a [FeedbackReportPreview]
/// as state and drives it through [FeedbackReportPreview.redactField] /
/// [FeedbackReportPreview.unredactField]; the displayed values come from
/// [FeedbackReportPreview.displayJson] (the model's own masking) and the
/// submitted payload from [FeedbackReportPreview.toSubmittableReport].
/// The redactable rows are enumerated from
/// [FeedbackReportPreview.redactableTopLevelFields] (plus `deviceInfo.*`),
/// so a field added to the model's set automatically gets a toggle rather
/// than being silently non-redactable. `stackTrace` and `breadcrumbs` are
/// shown read-only (the model deliberately excludes them — breadcrumbs are
/// sanitised at capture, and stripping structural fields would make the
/// report untriageable).
///
/// ## Presentation-only and host-agnostic
///
/// Dumb by design, like [CrashReportPrompt]: it takes a preview and
/// callbacks and knows nothing about routing or the crash-draft slots.
/// The crash path (#76 Slice 1b) presents it inside the crash overlay; the
/// user-initiated flow (Slice 2) will push it as a route. Both provide an
/// [Overlay] ancestor (the crash overlay's `Overlay.wrap`; the router's
/// Navigator) — required because the stack-trace [SelectableText] hosts its
/// selection toolbar in an [Overlay].
///
/// The #34 privacy contract holds: nothing is submitted until the user taps
/// send; redaction happens client-side before the payload is built.
class FeedbackReviewScreen extends StatefulWidget {
  const FeedbackReviewScreen({
    required this.preview,
    required this.onSubmit,
    required this.onCancel,
    required this.onClose,
    super.key,
  });

  /// The report to review, pre-seeded with any prior redactions. The crash
  /// path builds this via `FeedbackReportPreview.fromReport(draft
  /// .withUserComment(comment))`, so the woven comment is already part of
  /// the message shown here.
  final FeedbackReportPreview preview;

  /// Submits the finalised (redactions applied) report; the result drives
  /// the honest outcome state shown to the user ("sent" vs "saved to send
  /// later"), matching the #69 pattern.
  final Future<FeedbackSubmitResult> Function(FeedbackReport report) onSubmit;

  /// The user backed out of review before sending. The host returns to the
  /// compact prompt (crash path) or pops the route (Slice 2).
  final VoidCallback onCancel;

  /// The user dismissed the surface after a terminal outcome. The host
  /// clears the crash-draft slots (crash path) or pops the route.
  final VoidCallback onClose;

  /// Stable finder keys — tests use these so they hold across locales.
  static const Key sendButtonKey = Key('feedback_review.send');
  static const Key backButtonKey = Key('feedback_review.back');
  static const Key closeButtonKey = Key('feedback_review.close');
  static const Key sentConfirmationKey = Key('feedback_review.sent');
  static const Key queuedConfirmationKey = Key('feedback_review.queued');
  static const Key submissionFailedKey = Key('feedback_review.failed');
  static const Key submissionRejectedKey = Key('feedback_review.rejected');
  static const Key stackTraceSectionKey = Key('feedback_review.stack_trace');
  static const Key breadcrumbsSectionKey = Key('feedback_review.breadcrumbs');

  /// The redaction toggle key for [path] (a top-level field name or a
  /// `deviceInfo.<key>` dot-path). Stable across locales.
  static Key redactToggleKey(String path) =>
      Key('feedback_review.redact.$path');

  @override
  State<FeedbackReviewScreen> createState() => _FeedbackReviewScreenState();
}

enum _ReviewPhase { reviewing, sending, sent, queued, rejected, failed }

class _FeedbackReviewScreenState extends State<FeedbackReviewScreen> {
  /// The working preview. Intentionally seeded once and then owned as
  /// mutable State — each toggle produces a new preview via the model's
  /// redact/unredact, and that user progress lives here.
  ///
  /// Do NOT re-seed this from `widget.preview` in `didUpdateWidget`: that
  /// would wipe the user's in-progress redactions on any parent rebuild
  /// that hands down a new preview instance. Newest-crash-wins is a host
  /// concern (see `BgeApp`'s review slot), not this widget's.
  late FeedbackReportPreview _preview = widget.preview;
  _ReviewPhase _phase = _ReviewPhase.reviewing;

  bool _isRedacted(String path) => _preview.userRedactedFields.contains(path);

  void _toggle(String path, bool redact) {
    setState(() {
      _preview = redact
          ? _preview.redactField(path)
          : _preview.unredactField(path);
    });
  }

  Future<void> _send() async {
    setState(() => _phase = _ReviewPhase.sending);
    try {
      final result = await widget.onSubmit(_preview.toSubmittableReport());
      if (!mounted) return;
      setState(
        () => _phase = result == FeedbackSubmitResult.sent
            ? _ReviewPhase.sent
            : _ReviewPhase.queued,
      );
    } on FeedbackPermanentSubmissionException catch (error) {
      // #97: permanent rejection — deliberately not queued, so the
      // outcome copy must not promise a later send. The rejected copy
      // attributes the decision to the server, so it only renders for a
      // wire rejection (statusCode != null); a client-side validation
      // failure (null statusCode) falls to the generic failed copy,
      // which stays honest — not sent, not saved.
      if (!mounted) return;
      setState(
        () => _phase = error.statusCode != null
            ? _ReviewPhase.rejected
            : _ReviewPhase.failed,
      );
    } on Object {
      if (!mounted) return;
      setState(() => _phase = _ReviewPhase.failed);
    }
  }

  bool get _terminal =>
      _phase == _ReviewPhase.sent ||
      _phase == _ReviewPhase.queued ||
      _phase == _ReviewPhase.rejected ||
      _phase == _ReviewPhase.failed;

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final sending = _phase == _ReviewPhase.sending;

    return Scaffold(
      appBar: AppBar(
        title: Text(i18n.feedbackReviewTitle),
        automaticallyImplyLeading: false,
        leading: _terminal
            ? null
            : BackButton(
                key: FeedbackReviewScreen.backButtonKey,
                onPressed: sending ? null : widget.onCancel,
              ),
      ),
      body: switch (_phase) {
        _ReviewPhase.reviewing || _ReviewPhase.sending => _reviewing(i18n),
        _ReviewPhase.sent => _outcome(
          i18n,
          key: FeedbackReviewScreen.sentConfirmationKey,
          icon: Icons.check_circle_outline,
          text: i18n.feedbackReviewSent,
        ),
        _ReviewPhase.queued => _outcome(
          i18n,
          key: FeedbackReviewScreen.queuedConfirmationKey,
          icon: Icons.schedule_send_outlined,
          text: i18n.feedbackReviewQueued,
        ),
        _ReviewPhase.rejected => _outcome(
          i18n,
          key: FeedbackReviewScreen.submissionRejectedKey,
          icon: Icons.block_outlined,
          text: i18n.feedbackReviewRejected,
        ),
        _ReviewPhase.failed => _outcome(
          i18n,
          key: FeedbackReviewScreen.submissionFailedKey,
          icon: Icons.error_outline,
          text: i18n.feedbackReviewFailed,
        ),
      },
    );
  }

  Widget _reviewing(ShellLocalizations i18n) {
    final report = _preview.report;
    // Single serialization per build: displayJson() already derives from
    // report.toJson() and applies masking, so read BOTH the presence gate
    // (value != null) and the displayed value from it — no second toJson()
    // of the full breadcrumb/stack-trace payload each rebuild (#76 review).
    final display = _preview.displayJson();
    final deviceInfo = report.deviceInfo ?? const <String, dynamic>{};
    final deviceKeys = deviceInfo.keys.toList()..sort();
    final sending = _phase == _ReviewPhase.sending;

    String valueOf(String field) => (display[field] ?? '').toString();
    String deviceValueOf(String key) {
      final device = display['deviceInfo'];
      final source = device is Map<String, dynamic> ? device : deviceInfo;
      return (source[key] ?? '').toString();
    }

    String fieldLabel(String field) => switch (field) {
      'message' => i18n.feedbackReviewFieldMessage,
      'title' => i18n.feedbackReviewFieldTitle,
      'appVersion' => i18n.feedbackReviewFieldAppVersion,
      'platform' => i18n.feedbackReviewFieldPlatform,
      'locale' => i18n.feedbackReviewFieldLocale,
      // A field newly added to the model's redactable set that this screen
      // has no localized label for still gets a row + toggle under its raw
      // key — never silently non-redactable (#76 review).
      _ => field,
    };

    // Enumerate the redactable rows from the model's authoritative set
    // rather than hardcoded lists (#76 review). Known fields keep their
    // section and order; any *unknown* redactable field is still surfaced
    // (appended to the environment section) so it can never be silently
    // dropped from review.
    final redactable = FeedbackReportPreview.redactableTopLevelFields;
    const reportFields = <String>['message', 'title'];
    const envFields = <String>['appVersion', 'platform', 'locale'];
    final knownFields = <String>{...reportFields, ...envFields};
    final extraFields =
        redactable.where((field) => !knownFields.contains(field)).toList()
          ..sort();

    bool renders(String field) =>
        redactable.contains(field) && display[field] != null;

    Widget redactRow(String field) => _redactRow(
      path: field,
      label: fieldLabel(field),
      value: valueOf(field),
      enabled: !sending,
    );

    final reportRows = <Widget>[
      for (final field in reportFields)
        if (renders(field)) redactRow(field),
    ];
    final environmentRows = <Widget>[
      for (final field in [...envFields, ...extraFields])
        if (renders(field)) redactRow(field),
    ];
    final deviceRows = <Widget>[
      for (final key in deviceKeys)
        _redactRow(
          path: '${FeedbackReportPreview.deviceInfoPrefix}$key',
          label: key,
          value: deviceValueOf(key),
          enabled: !sending,
        ),
    ];
    final diagnostics = <Widget>[
      if (report.stackTrace case final trace? when trace.isNotEmpty)
        _stackTraceSection(i18n, trace),
      if (report.breadcrumbs.isNotEmpty)
        _breadcrumbsSection(i18n, report.breadcrumbs),
    ];

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(i18n.feedbackReviewExplanation),
              ),
              _sectionHeader(i18n.feedbackReviewSectionReport),
              _readOnlyRow(
                i18n.feedbackReviewFieldCategory,
                report.category.toWire(),
              ),
              if (report.severity != null)
                _readOnlyRow(
                  i18n.feedbackReviewFieldSeverity,
                  report.severity!.toWire(),
                ),
              ...reportRows,
              if (environmentRows.isNotEmpty) ...[
                _sectionHeader(i18n.feedbackReviewSectionEnvironment),
                ...environmentRows,
              ],
              if (deviceRows.isNotEmpty) ...[
                _sectionHeader(i18n.feedbackReviewSectionDevice),
                ...deviceRows,
              ],
              if (diagnostics.isNotEmpty) ...[
                _sectionHeader(i18n.feedbackReviewSectionDiagnostics),
                ...diagnostics,
              ],
            ],
          ),
        ),
        _footer(i18n, sending: sending),
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    ),
  );

  Widget _readOnlyRow(String label, String value) =>
      ListTile(dense: true, title: Text(label), subtitle: Text(value));

  /// A redaction toggle row. The [SwitchListTile] is a semantic toggle
  /// (its on/off state and [label] are announced by assistive tech); the
  /// value below is wrapped in a live region so the `<redacted>`
  /// substitution is announced when the switch flips (WCAG, #76).
  Widget _redactRow({
    required String path,
    required String label,
    required String value,
    required bool enabled,
  }) {
    return SwitchListTile(
      key: FeedbackReviewScreen.redactToggleKey(path),
      value: _isRedacted(path),
      onChanged: enabled ? (redact) => _toggle(path, redact) : null,
      title: Text(label),
      subtitle: Semantics(liveRegion: true, child: Text(value)),
    );
  }

  Widget _stackTraceSection(ShellLocalizations i18n, String trace) =>
      ExpansionTile(
        key: FeedbackReviewScreen.stackTraceSectionKey,
        title: Text(i18n.feedbackReviewStackTrace),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          SelectableText(
            trace,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      );

  Widget _breadcrumbsSection(
    ShellLocalizations i18n,
    List<Breadcrumb> crumbs,
  ) => ExpansionTile(
    key: FeedbackReviewScreen.breadcrumbsSectionKey,
    title: Text(i18n.feedbackReviewBreadcrumbs),
    children: [
      for (final crumb in crumbs)
        ListTile(
          dense: true,
          leading: Text(crumb.level.toWire()),
          title: Text(crumb.message),
          subtitle: Text(crumb.loggerName),
        ),
    ],
  );

  Widget _footer(ShellLocalizations i18n, {required bool sending}) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: FeedbackReviewScreen.sendButtonKey,
          onPressed: sending ? null : _send,
          child: sending
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(i18n.feedbackReviewSend),
        ),
      ),
    ),
  );

  /// Terminal outcome: an announced status line plus a dismiss affordance,
  /// mirroring [CrashReportPrompt]'s outcome states.
  Widget _outcome(
    ShellLocalizations i18n, {
    required Key key,
    required IconData icon,
    required String text,
  }) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: FeedbackReviewScreen.closeButtonKey,
                onPressed: widget.onClose,
                child: Text(i18n.feedbackReviewClose),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
