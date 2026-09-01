import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
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
/// The crash path presents it inside the crash overlay; the
/// user-initiated flow will push it as a route. Both provide an
/// [Overlay] ancestor (the crash overlay's `Overlay.wrap`; the router's
/// Navigator) — required because the stack-trace [SelectableText] hosts its
/// selection toolbar in an [Overlay].
///
/// **That [SelectableText] is not redundant with the app-wide selection
/// region** (#322). Three presentations, and it is load-bearing in two: on
/// the crash path this screen is a *sibling* of the region's content in
/// `BgeApp`'s overlay stack, so the region never reaches it
/// (`bge_app_selection_test.dart` pins that); and on touch platforms there
/// is no region at all. Only the routed presentation on a pointer platform
/// puts it inside the region, where it nests harmlessly — a `SelectableText`
/// inside a `SelectionArea` builds and selects fine, it simply runs its own
/// selection rather than joining the region's. Deleting it would silently
/// break the other two.
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
  /// compact prompt (crash path) or pops the route.
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
  static const Key copyButtonKey = Key('feedback_review.copy');
  static const Key stackTraceSectionKey = Key('feedback_review.stack_trace');
  static const Key breadcrumbsSectionKey = Key('feedback_review.breadcrumbs');

  /// Key on the review list — the content column the measure caps.
  static const Key reviewListKey = Key('feedback_review.list');

  /// The redaction toggle key for [path] (a top-level field name or a
  /// `deviceInfo.<key>` dot-path). Stable across locales.
  static Key redactToggleKey(String path) =>
      Key('feedback_review.redact.$path');

  @override
  State<FeedbackReviewScreen> createState() => _FeedbackReviewScreenState();
}

enum _ReviewPhase { reviewing, sending, sent, queued, rejected, failed }

class _FeedbackReviewScreenState extends State<FeedbackReviewScreen> {
  static final BgeLogger _log = BgeLogger('bge.shell.feedback_review');

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

  /// Identifies the most recent copy attempt, so a completion can tell
  /// whether it still speaks for the screen. See [_copy].
  int _copyToken = 0;

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

  /// Whether the report is still the user's to salvage.
  ///
  /// Not the complement of [_terminal], and the difference is the point:
  /// `rejected` and `failed` are terminal, but the report was neither
  /// delivered nor saved to send later — the only affordance on those states
  /// is Close, which drops it. Hiding the copy action there would take the
  /// report away at exactly the moment it became unrecoverable. `sent` and
  /// `queued` are the two where it is genuinely gone from the user's hands.
  bool get _copyable => switch (_phase) {
    _ReviewPhase.reviewing ||
    _ReviewPhase.sending ||
    _ReviewPhase.rejected ||
    _ReviewPhase.failed => true,
    _ReviewPhase.sent || _ReviewPhase.queued => false,
  };

  bool get _terminal =>
      _phase == _ReviewPhase.sent ||
      _phase == _ReviewPhase.queued ||
      _phase == _ReviewPhase.rejected ||
      _phase == _ReviewPhase.failed;

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final sending = _phase == _ReviewPhase.sending;

    // The complement of _terminal by construction; deriving it rather than
    // re-listing the phases keeps the two from drifting apart.
    final reviewing = !_terminal;
    final rows = reviewing ? _reviewRows(i18n) : null;

    return BgePage.slivers(
      title: Text(i18n.feedbackReviewTitle),
      automaticallyImplyLeading: false,
      leading: _terminal
          ? null
          : BackButton(
              key: FeedbackReviewScreen.backButtonKey,
              onPressed: sending ? null : widget.onCancel,
            ),
      // #322: the reliable way off this screen with the report in hand. On
      // touch there is no selection region at all; on pointer platforms
      // there is one, but dragging across these rows yields their labels and
      // values run together with no separators — the concatenation problem
      // that decided the shape of #322. A button that emits the same JSON
      // the rows are rendered from beats both, so it is not platform-gated.
      actions: _copyable
          ? [
              IconButton(
                key: FeedbackReviewScreen.copyButtonKey,
                icon: const Icon(Icons.copy_outlined),
                tooltip: i18n.feedbackReviewCopy,
                onPressed: sending ? null : () => _copy(i18n),
              ),
            ]
          : null,
      // Step one of this flow (compose) is a BgePage; this is step two. Built
      // on a raw Scaffold, the content column snapped from the form measure to
      // the full window halfway through the flow — visible as a jump on any
      // desktop window (#191).
      //
      // The send button is the page footer rather than the last row of the
      // list so it stays reachable on a long report, which is what the
      // Expanded+Column here used to buy.
      footer: reviewing ? _footer(i18n, sending: sending) : null,
      padding: EdgeInsets.zero,
      // The count a screen reader reads as "item 3 of 9". CustomScrollView
      // cannot infer it the way ListView(children:) does. Null on the
      // terminal states, which are one message rather than a collection.
      semanticChildCount: rows?.length,
      slivers: switch (_phase) {
        _ReviewPhase.reviewing || _ReviewPhase.sending => [
          SliverPadding(
            padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
            // A SliverList through BgePage.slivers, so the page keeps one
            // real viewport: these rows are a collection a screen reader
            // navigates, and a list nested inside a box scroll view loses
            // its `scrollChildCount`. See SettingsScreen for the measurement.
            sliver: SliverList.list(
              key: FeedbackReviewScreen.reviewListKey,
              children: rows!,
            ),
          ),
        ],
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

  List<Widget> _reviewRows(ShellLocalizations i18n) {
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

    final tokens = BgeTokens.of(context);
    return [
      Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spaceMd,
          tokens.spaceMd,
          tokens.spaceMd,
          tokens.spaceSm,
        ),
        child: Text(i18n.feedbackReviewExplanation),
      ),
      _sectionHeader(i18n.feedbackReviewSectionReport),
      _readOnlyRow(i18n.feedbackReviewFieldCategory, report.category.toWire()),
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
    ];
  }

  Widget _sectionHeader(String text) => Padding(
    padding: EdgeInsets.fromLTRB(
      BgeTokens.of(context).spaceMd,
      BgeTokens.of(context).spaceMd,
      BgeTokens.of(context).spaceMd,
      BgeTokens.of(context).spaceXs,
    ),
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
        childrenPadding: EdgeInsets.fromLTRB(
          BgeTokens.of(context).spaceMd,
          0,
          BgeTokens.of(context).spaceMd,
          BgeTokens.of(context).spaceMd,
        ),
        children: [
          SelectableText(
            trace,
            // Monospace is load-bearing here — a stack trace's alignment is
            // information — so this legitimately sits outside the type scale.
            // It still derives from it: bodySmall supplies the size and the
            // scheme supplies the color, and only the family is overridden.
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontFamily: BgeTypography.monospaceFamily),
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

  /// Puts the reviewed report on the clipboard (#322).
  ///
  /// Serializes [FeedbackReportPreview.displayJson] — *what is on screen* —
  /// and deliberately not `toSubmittableReport()`. They differ: the
  /// submittable report is what the server would receive, and copying that
  /// would hand the user a payload containing values they had just redacted.
  /// The #34 privacy contract governs the clipboard the same as the wire.
  Future<void> _copy(ShellLocalizations i18n) async {
    // Claimed before the first await: taps are not serialized, so several
    // round-trips can be in flight at once and the platform is under no
    // obligation to answer them in order.
    final token = ++_copyToken;
    // `toEncodable` is a floor, not an expectation: `displayJson()` derives
    // from `toJson()` and is JSON-safe today, but `deviceInfo` is free-form
    // `Map<String, dynamic>` and is expected to grow. A future value that
    // is not a primitive should degrade to its string form rather than
    // throw in the user's hands while they are reporting a crash.
    final encoder = JsonEncoder.withIndent('  ', (value) => value.toString());
    var copied = false;
    try {
      final text = encoder.convert(_preview.displayJson());
      await Clipboard.setData(ClipboardData(text: text));
      copied = true;
    } on Object catch (error, stackTrace) {
      // Not rethrown, and that is load-bearing: `onPressed` discards this
      // Future, so an escaping error reaches `PlatformDispatcher.onError`,
      // which `global_error_hooks` turns into a crash report — a failed copy
      // would summon a fresh crash prompt on top of the crash the user is
      // already trying to report.
      //
      // Logged rather than swallowed outright, because this is the one flow
      // whose entire job is producing diagnostics. Without a record, a
      // clipboard that systematically fails on one platform is invisible to
      // everyone but the user staring at "couldn't copy".
      _log.warn(
        'Copying the feedback report to the clipboard failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Logged above regardless, because a failure is worth recording whether
    // or not it still owns the screen — but a superseded attempt says
    // nothing to the user. Without this, a slow first tap that failed lands
    // after a fast second tap that succeeded and overwrites "copied" with
    // "couldn't copy", which is the worst available lie for a flow whose
    // entire job is producing diagnostics.
    if (!mounted || token != _copyToken) return;
    // The SnackBar is the whole confirmation, sighted and otherwise: it is
    // already a live region (`snack_bar.dart`), so it announces on its own.
    // Deliberately no `SemanticsService.announce` alongside it — deprecated,
    // and on Android an announcement event makes TalkBack drop its speech
    // queue. Same reasoning as `UnverifiedSessionBanner` and #191.
    //
    // Cleared first because `showSnackBar` *queues*: `Clipboard.setData` is an
    // async platform round-trip, so the button looks inert and people tap it
    // again — and three taps stacked three confirmations that replayed for
    // over fifteen seconds, long after the copy was done. Only the newest
    // outcome is true, and it is the only one worth showing. `clearSnackBars`
    // rather than `removeCurrentSnackBar`: the latter merely promotes the next
    // bar in the queue, which is the same bug one position along.
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            copied ? i18n.feedbackReviewCopied : i18n.feedbackReviewCopyFailed,
          ),
        ),
      );
  }

  Widget _footer(ShellLocalizations i18n, {required bool sending}) => SafeArea(
    top: false,
    child: Padding(
      padding: EdgeInsets.all(BgeTokens.of(context).spaceMd),
      // Was a hand-rolled in-flight button with a bare spinner: while sending,
      // it announced as an unnamed disabled button. BgeSubmitButton keeps the
      // accessible name and announces the state change (#165).
      child: BgeSubmitButton(
        key: FeedbackReviewScreen.sendButtonKey,
        label: i18n.feedbackReviewSend,
        progressLabel: i18n.feedbackReviewSending,
        submitting: sending,
        onPressed: _send,
      ),
    ),
  );

  /// Terminal outcome: an announced status line plus a dismiss affordance,
  /// mirroring [CrashReportPrompt]'s outcome states.
  List<Widget> _outcome(
    ShellLocalizations i18n, {
    required Key key,
    required IconData icon,
    required String text,
  }) => [
    // Fills whatever the viewport has left and centres in it — the sliver
    // equivalent of the box path's `centerVertically`, which a lazy list
    // cannot use because it has no total height.
    SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: _outcomeBody(i18n, key: key, icon: icon, text: text),
      ),
    ),
  ];

  Widget _outcomeBody(
    ShellLocalizations i18n, {
    required Key key,
    required IconData icon,
    required String text,
  }) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(BgeTokens.of(context).spaceMd),
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
                  const BgeGap.sm(axis: Axis.horizontal),
                  Expanded(child: Text(text)),
                ],
              ),
            ),
            const BgeGap.md(),
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
