import 'package:freezed_annotation/freezed_annotation.dart';

import '../breadcrumbs/breadcrumb.dart';
import 'feedback_category.dart';
import 'feedback_constants.dart';
import 'feedback_context.dart';
import 'feedback_severity.dart';

part 'feedback_report.freezed.dart';
part 'feedback_report.g.dart';

/// A client-assembled feedback report (issue #8; "BugReport" in the
/// original issue text, renamed to match the backend's generalised
/// FeedbackReport domain from backend PR #77).
///
/// Field set mirrors `CreateFeedbackReportDto`
/// (`libs/api/feedback/src/lib/dto/create-feedback-report.dto.ts` in
/// `board-games-empire-backend`) with one client-side extension:
///
/// - [breadcrumbs] has NO backend counterpart yet. It serialises here so
///   offline-queued draft reports persist their context, but the
///   transport mapping (dedicated DTO field vs embedding) is decided by
///   the concrete FeedbackService implementations once the backend grows
///   a breadcrumb field. Noted for backend follow-up.
///
/// Invariants enforced at construction (mirroring the DTO's ValidateIf
/// and IsNotEmpty rules):
///
/// - [severity] is required when [category] is [FeedbackCategory.crash]
///   or [FeedbackCategory.bug]; feature requests carry none.
/// - [message] must be non-empty.
///
/// Length caps are NOT construction-time asserts — a user typing past a
/// cap is expected input, not a programming error. [validate] reports
/// cap violations for the submission UI to surface.
@freezed
abstract class FeedbackReport with _$FeedbackReport {
  @Assert(
    '!(category == FeedbackCategory.crash || '
        'category == FeedbackCategory.bug) || severity != null',
    'severity is required when category is crash or bug',
  )
  // `message != ""` rather than `message.isNotEmpty`: const constructor
  // asserts only admit potentially-constant expressions, and property
  // access on a parameter (`.isNotEmpty`) is not one — `==`/`!=` against
  // a String literal is.
  @Assert("message != ''", 'message must not be empty')
  const factory FeedbackReport({
    /// What kind of report this is.
    required FeedbackCategory category,

    /// Free-form report body. Capped at
    /// [FeedbackConstants.maxMessageLength]; see [validate].
    required String message,

    /// Short title; surfaced as the GitHub issue title when forwarded
    /// by a backend sink.
    String? title,

    /// Client- vs server-side scope.
    @Default(FeedbackContext.unknown) FeedbackContext context,

    /// Severity. Required for crash/bug categories (constructor assert).
    FeedbackSeverity? severity,

    /// Submitting client app version (e.g. `0.4.1`).
    String? appVersion,

    /// Submitting platform (e.g. `android`, `macos`, `web`).
    String? platform,

    /// BCP-47 locale (e.g. `en-US`).
    String? locale,

    /// Free-form device/environment context. Keys here are user-
    /// redactable via dot-paths on FeedbackReportPreview.
    Map<String, dynamic>? deviceInfo,

    /// Idempotency token — unique per (user, report) on the backend, so
    /// offline-queue retries don't create duplicates.
    String? correlationKey,

    /// Field paths redacted before submission. Sets
    /// `redactionApplied=true` server-side.
    @Default(<String>[]) List<String> userRedactedFields,

    /// Sanitised log trail captured at build time. Client-side
    /// extension — see class doc.
    @Default(<Breadcrumb>[]) List<Breadcrumb> breadcrumbs,
  }) = _FeedbackReport;

  const FeedbackReport._();

  factory FeedbackReport.fromJson(Map<String, dynamic> json) =>
      _$FeedbackReportFromJson(json);

  /// Checks every backend protocol cap from [FeedbackConstants] and
  /// returns human-readable violations (empty when submittable). Each
  /// violation names the offending field, so the submission UI can map
  /// messages onto inputs.
  List<String> validate() {
    final violations = <String>[];

    // The constructor asserts re-stated as runtime checks: asserts are
    // stripped in release builds, so an invalid report — e.g. a
    // corrupted offline-persisted draft rehydrated via [fromJson] —
    // can exist there. Re-checking here lets submit() implementations
    // reject it reliably in every build mode. (Under `dart test`
    // asserts are active, so these branches are unreachable in the
    // suite — the construction-time AssertionError specs cover the
    // debug path.)
    if (message.isEmpty) {
      violations.add('message must not be empty');
    }
    if ((category == FeedbackCategory.crash ||
            category == FeedbackCategory.bug) &&
        severity == null) {
      violations.add(
        'severity is required when category is ${category.toWire()}',
      );
    }

    void cap(String field, String? value, int max) {
      if (value != null && value.length > max) {
        violations.add('$field exceeds $max characters (${value.length})');
      }
    }

    cap('message', message, FeedbackConstants.maxMessageLength);
    cap('title', title, FeedbackConstants.maxTitleLength);
    cap('appVersion', appVersion, FeedbackConstants.maxAppVersionLength);
    cap('platform', platform, FeedbackConstants.maxPlatformLength);
    cap('locale', locale, FeedbackConstants.maxLocaleLength);
    cap(
      'correlationKey',
      correlationKey,
      FeedbackConstants.maxCorrelationKeyLength,
    );

    if (userRedactedFields.length > FeedbackConstants.maxRedactedFields) {
      violations.add(
        'userRedactedFields exceeds '
        '${FeedbackConstants.maxRedactedFields} entries '
        '(${userRedactedFields.length})',
      );
    }

    return violations;
  }

  /// Whether [validate] reports no violations.
  bool get isValid => validate().isEmpty;
}
