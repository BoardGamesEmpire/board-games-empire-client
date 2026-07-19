import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
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

class _FeedbackFlowScreenState extends State<FeedbackFlowScreen> {
  late final FeedbackComposeFormModel _model = FeedbackComposeFormModel();

  /// Non-null while the review phase is showing.
  FeedbackReportPreview? _preview;

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

  void _backToCompose() => setState(() => _preview = null);

  @override
  Widget build(BuildContext context) {
    final preview = _preview;

    // Route-level back semantics: on the compose phase the route pops
    // normally (system back and the AppBar back leave the flow); on the
    // review phase system back bounces to compose — matching the review
    // surface's visible BackButton — instead of popping the route. Unlike
    // the crash overlay (#106), this IS a real route, so PopScope is the
    // correct primitive here.
    return PopScope(
      canPop: preview == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToCompose();
      },
      child: preview == null ? _compose(context) : _review(preview),
    );
  }

  Widget _compose(BuildContext context) {
    final l10n = FeedbackLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.feedbackComposeTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: FeedbackComposeForm(model: _model, onSubmit: _onCompose),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _review(FeedbackReportPreview preview) => FeedbackReviewScreen(
    preview: preview,
    onSubmit: widget.feedbackService.submit,
    // The user backed out before sending → compose, input intact.
    onCancel: _backToCompose,
    // Terminal outcome dismissed → leave the flow. The route's Navigator
    // (go_router's) pops this page.
    onClose: () => Navigator.of(context).pop(),
  );
}
