import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:observability/observability.dart';

import '../widgets/feedback_review_screen.dart';

/// The user-initiated feedback flow (#107): a single route hosting the
/// compose step (the `feedback` feature's [FeedbackComposeForm]) that
/// terminates in the shared review & redaction surface
/// ([FeedbackReviewScreen], #76).
///
/// One route, two phases — deliberately not two routes: the review
/// surface takes a non-serializable [FeedbackReportPreview], so a
/// separate `/feedback/review` location would need `extra` (fragile on
/// web refresh, pollutes the deep-link surface). The phase lives here as
/// widget state instead (see the #107 decision record).
///
/// State preservation: this screen owns the [FeedbackComposeFormModel]
/// for its lifetime, so backing out of review (the review's `BackButton`,
/// or system back via the [PopScope] below) restores the compose step
/// with the user's input intact.
///
/// Once the user taps send, system back follows the send's stage (#179):
///
/// | Stage | System back |
/// |---|---|
/// | sending | does nothing |
/// | delivered (sent, or saved to send later) | leaves the flow |
/// | undelivered (the submit threw) | returns to compose, input intact |
///
/// Bouncing a delivered report back to its filled form invited a second
/// send, and every send builds a new report with a new `clientRequestId`, so
/// the server could not tell the two apart. A report that never got out is
/// still the user's to edit and retry.
///
/// Composition lives in app_shell, not the feature: the review surface is
/// shell-owned and app_shell depends on features, never the reverse. The
/// host (BgeApp) resolves the device-global [FeedbackService] from the
/// root container and injects it here — decoupled from the crash
/// reporter, which may legitimately be absent.
///
/// Wiring on submit: `message` maps to `userComment` (`errorMessage`
/// stays null — satisfying the service's at-least-one-non-empty rule);
/// category, severity, and title pass through. The #34 privacy contract
/// holds — nothing is sent until the user taps send on the review
/// surface, and [FeedbackService.submit]'s honest sent/queued outcome is
/// surfaced there.
class FeedbackFlowScreen extends StatefulWidget {
  const FeedbackFlowScreen({required this.feedbackService, super.key});

  /// The device-global service (#72) used to build the report from the
  /// compose result and, from the review surface, submit it.
  final FeedbackService feedbackService;

  @override
  State<FeedbackFlowScreen> createState() => _FeedbackFlowScreenState();
}

/// Where the review phase's send has got to; drives system back (#179).
enum _SendStage { idle, sending, delivered, undelivered }

class _FeedbackFlowScreenState extends State<FeedbackFlowScreen> {
  late final FeedbackComposeFormModel _model = FeedbackComposeFormModel();

  /// Non-null while the review phase is showing.
  FeedbackReportPreview? _preview;

  _SendStage _stage = _SendStage.idle;

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  void _onCompose(FeedbackComposeResult result) {
    final report = widget.feedbackService.buildReport(
      category: result.category,
      severity: result.severity,
      title: result.title,
      userComment: result.message,
    );
    setState(() => _preview = FeedbackReportPreview.fromReport(report));
  }

  void _backToCompose() => setState(() {
    _preview = null;
    _stage = _SendStage.idle;
  });

  /// The review surface's submit, tracked so back knows whether the report
  /// is out. A throw is rethrown untouched: the review surface renders the
  /// rejected and failed outcomes from it.
  Future<FeedbackSubmitResult> _submit(FeedbackReport report) async {
    setState(() => _stage = _SendStage.sending);
    try {
      final result = await widget.feedbackService.submit(report);
      if (mounted) setState(() => _stage = _SendStage.delivered);
      return result;
    } catch (_) {
      if (mounted) setState(() => _stage = _SendStage.undelivered);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;

    // Route-level back semantics: on the compose phase the route pops
    // normally (system back and the AppBar back leave the flow), and so it
    // does once the report is delivered (#179). Before sending, and after a
    // send that threw, system back bounces to compose — matching the review
    // surface's visible BackButton — instead of popping the route; while
    // sending it does nothing. Unlike the crash overlay (#106), this IS a
    // real route, so PopScope is the correct primitive here.
    return PopScope(
      canPop: preview == null || _stage == _SendStage.delivered,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _stage == _SendStage.sending) return;
        _backToCompose();
      },
      child: preview == null ? _compose(context) : _review(preview),
    );
  }

  /// Step one. Built to hand over to step two in place (#211): the review
  /// surface pins its send button and insets its column by `spaceMd`, so this
  /// step pins "Review report" and takes the same inset. Anything else and
  /// the button and the text column visibly move at the handoff — measured,
  /// by 8dp on a phone and 16dp a side on a desktop window. #191 fixed the
  /// column's width jump at this handoff; this is the inset mismatch it left.
  Widget _compose(BuildContext context) {
    final l10n = FeedbackLocalizations.of(context);
    final spaceMd = BgeTokens.of(context).spaceMd;
    final form = FeedbackComposeForm(model: _model, onSubmit: _onCompose);
    return BgePage(
      title: Text(l10n.feedbackComposeTitle),
      padding: EdgeInsets.all(spaceMd),
      // The same gap above the button as review's, for the same reason.
      footer: Padding(
        padding: EdgeInsets.only(top: spaceMd),
        child: FeedbackComposeSubmitButton(form: form),
      ),
      child: form,
    );
  }

  Widget _review(FeedbackReportPreview preview) => FeedbackReviewScreen(
    preview: preview,
    onSubmit: _submit,
    // The user backed out before sending → compose, input intact.
    onCancel: _backToCompose,
    // Terminal outcome dismissed → leave the flow. The route's Navigator
    // (go_router's) pops this page.
    onClose: () => Navigator.of(context).pop(),
  );
}
