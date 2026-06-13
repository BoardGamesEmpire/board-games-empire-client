import 'package:freezed_annotation/freezed_annotation.dart';

import 'feedback_report.dart';

part 'feedback_report_preview.freezed.dart';

/// The consent-screen model for a [FeedbackReport] (issue #8): shows the
/// user exactly what would be submitted and lets them redact additional
/// fields before sending.
///
/// Redacted fields are visibly marked with [redactedMarker] rather than
/// removed — the reviewer (and the backend triager) can see that a value
/// existed and was withheld, which is materially different from the value
/// never having been collected.
///
/// ## What is redactable
///
/// Only string-valued payload fields and `deviceInfo.<key>` dot-paths
/// (see [redactableTopLevelFields]). Structural fields — category,
/// severity, context — are not: a `<redacted>` enum can't round-trip,
/// and stripping them would make the report untriageable. Breadcrumbs
/// are already sanitised at capture; per-crumb redaction is a future
/// UI-layer concern, not part of this model.
///
/// ## Seeding from a persisted draft
///
/// The bare constructor's [userRedactedFields] defaults to the empty
/// set, NOT the report's — it's an explicit-set entry point.
/// [FeedbackReportPreview.fromReport] is the right call for the common
/// case (previewing a draft whose own `userRedactedFields` already
/// carries prior marks): it seeds the preview's set from the report so
/// [unredactField] can toggle those off and [toSubmittableReport]
/// reflects the final intent.
///
/// The preview is immutable: [redactField] / [unredactField] return new
/// instances, so the consent screen can treat it as ordinary bloc state.
@freezed
abstract class FeedbackReportPreview with _$FeedbackReportPreview {
  const factory FeedbackReportPreview({
    /// The underlying report being previewed.
    required FeedbackReport report,

    /// Field paths the user has redacted in this preview session.
    /// THIS is the authoritative final set used by
    /// [toSubmittableReport]; the report's own `userRedactedFields`
    /// is NOT unioned in at submit time. Seed via
    /// [FeedbackReportPreview.fromReport] when previewing a draft
    /// whose paths should be carried forward.
    @Default(<String>{}) Set<String> userRedactedFields,
  }) = _FeedbackReportPreview;

  /// Creates a preview seeded with the redactions already on [report].
  ///
  /// Equivalent to passing `userRedactedFields: {...report.userRedactedFields}`
  /// — the named factory exists so call sites that preview a persisted
  /// draft read at a glance, and so callers can't accidentally drop
  /// prior marks by forgetting to seed manually.
  factory FeedbackReportPreview.fromReport(FeedbackReport report) =>
      FeedbackReportPreview(
        report: report,
        userRedactedFields: {...report.userRedactedFields},
      );

  const FeedbackReportPreview._();

  /// Marker substituted for redacted values. Matches
  /// `Redaction.defaultReplacement` by convention.
  static const String redactedMarker = '<redacted>';

  /// Top-level fields the user may redact. String-valued payload fields
  /// only — see class doc for why structural fields are excluded.
  static const Set<String> redactableTopLevelFields = {
    'title',
    'message',
    'appVersion',
    'platform',
    'locale',
  };

  /// Prefix for `deviceInfo` key dot-paths (e.g. `deviceInfo.model`).
  static const String deviceInfoPrefix = 'deviceInfo.';

  /// Whether [path] is a field the user may redact.
  bool isRedactable(String path) =>
      redactableTopLevelFields.contains(path) ||
      (path.startsWith(deviceInfoPrefix) &&
          path.length > deviceInfoPrefix.length);

  /// Returns a new preview with [path] redacted.
  ///
  /// Throws [ArgumentError] when [path] is not redactable — the consent
  /// UI should only offer redaction affordances for [isRedactable]
  /// fields, so a bad path here is a programming error worth surfacing.
  FeedbackReportPreview redactField(String path) {
    if (!isRedactable(path)) {
      throw ArgumentError.value(path, 'path', 'not a redactable field');
    }
    return copyWith(userRedactedFields: {...userRedactedFields, path});
  }

  /// Returns a new preview with [path] no longer redacted. Unknown paths
  /// are a no-op.
  FeedbackReportPreview unredactField(String path) =>
      copyWith(userRedactedFields: {...userRedactedFields}..remove(path));

  /// The report's JSON with this preview's redactions visibly applied —
  /// what the consent screen renders. Only non-null values are marked;
  /// a redacted-but-absent (or null) field stays absent rather than
  /// gaining a phantom marker.
  Map<String, dynamic> displayJson() {
    final out = {...report.toJson()};
    // Lazily cloned once on the first deviceInfo.<key> redaction, then
    // mutated in place — re-spreading the map per redacted key would
    // allocate a fresh copy for every path.
    Map<String, dynamic>? device;
    for (final path in userRedactedFields) {
      if (path.startsWith(deviceInfoPrefix)) {
        device ??= switch (out['deviceInfo']) {
          final Map<String, dynamic> map => {...map},
          _ => null,
        };
        if (device == null) continue;
        final key = path.substring(deviceInfoPrefix.length);
        if (device[key] != null) {
          device[key] = redactedMarker;
        }
      } else if (out[path] != null) {
        out[path] = redactedMarker;
      }
    }
    if (device != null) {
      out['deviceInfo'] = device;
    }
    // Preview's set is authoritative; the report's own list (carried in
    // by report.toJson()) would otherwise diverge from toSubmittableReport().
    out['userRedactedFields'] = userRedactedFields.toList()..sort();
    return out;
  }

  /// Materialises the preview into the report that should actually be
  /// submitted: redacted values replaced with [redactedMarker], and the
  /// preview's sorted [userRedactedFields] copied into
  /// [FeedbackReport.userRedactedFields] so the backend sets
  /// `redactionApplied`. The report's own `userRedactedFields` is NOT
  /// unioned in — see the "Seeding from a persisted draft" class doc.
  ///
  /// Null values aren't marked (matches `displayJson`'s non-null rule):
  /// a redacted-but-null field stays null rather than gaining a phantom
  /// marker.
  ///
  /// Returns [report] unchanged when both the preview's set and the
  /// report's own `userRedactedFields` are empty.
  FeedbackReport toSubmittableReport() {
    // Early-out only when the preview AND the report both carry no
    // marks — otherwise the preview's set is the authoritative final
    // intent (incl. an explicit "unredact everything" override), so
    // we re-materialise even when our own set is empty.
    if (userRedactedFields.isEmpty && report.userRedactedFields.isEmpty) {
      return report;
    }

    String? maskIf(String field, String? value) =>
        userRedactedFields.contains(field) && value != null
        ? redactedMarker
        : value;

    var deviceInfo = report.deviceInfo;
    final devicePaths = userRedactedFields
        .where((path) => path.startsWith(deviceInfoPrefix))
        .toList();
    if (deviceInfo != null && devicePaths.isNotEmpty) {
      deviceInfo = {...deviceInfo};
      for (final path in devicePaths) {
        final key = path.substring(deviceInfoPrefix.length);
        if (deviceInfo[key] != null) {
          deviceInfo[key] = redactedMarker;
        }
      }
    }

    // The preview's set IS the final intent — no union with
    // `report.userRedactedFields`. Seeding (when desired) happens
    // upfront via [FeedbackReportPreview.fromReport], which lets
    // [unredactField] genuinely toggle a seeded path off.
    return report.copyWith(
      title: maskIf('title', report.title),
      message: userRedactedFields.contains('message')
          ? redactedMarker
          : report.message,
      appVersion: maskIf('appVersion', report.appVersion),
      platform: maskIf('platform', report.platform),
      locale: maskIf('locale', report.locale),
      deviceInfo: deviceInfo,
      userRedactedFields: userRedactedFields.toList()..sort(),
    );
  }
}
