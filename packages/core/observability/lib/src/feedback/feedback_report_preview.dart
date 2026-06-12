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
/// The preview is immutable: [redactField] / [unredactField] return new
/// instances, so the consent screen can treat it as ordinary bloc state.
@freezed
abstract class FeedbackReportPreview with _$FeedbackReportPreview {
  const factory FeedbackReportPreview({
    /// The underlying report being previewed.
    required FeedbackReport report,

    /// Field paths the user has redacted in this preview session.
    /// Merged with any paths already on [FeedbackReport.userRedactedFields]
    /// at submission time.
    @Default(<String>{}) Set<String> userRedactedFields,
  }) = _FeedbackReportPreview;

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
  /// a redacted-but-absent field stays absent rather than gaining a
  /// phantom marker.
  Map<String, dynamic> displayJson() {
    final out = {...report.toJson()};
    for (final path in userRedactedFields) {
      if (path.startsWith(deviceInfoPrefix)) {
        final device = out['deviceInfo'];
        if (device is Map<String, dynamic>) {
          final key = path.substring(deviceInfoPrefix.length);
          if (device.containsKey(key)) {
            out['deviceInfo'] = {...device, key: redactedMarker};
          }
        }
      } else if (out[path] != null) {
        out[path] = redactedMarker;
      }
    }
    return out;
  }

  /// Materialises the preview into the report that should actually be
  /// submitted: redacted values replaced with [redactedMarker], and the
  /// redacted paths merged (sorted) into
  /// [FeedbackReport.userRedactedFields] so the backend sets
  /// `redactionApplied`.
  ///
  /// With no preview-session redactions the underlying report is
  /// returned as-is.
  FeedbackReport toSubmittableReport() {
    if (userRedactedFields.isEmpty) return report;

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
        if (deviceInfo.containsKey(key)) {
          deviceInfo[key] = redactedMarker;
        }
      }
    }

    final mergedPaths =
        {...report.userRedactedFields, ...userRedactedFields}.toList()..sort();

    return report.copyWith(
      title: maskIf('title', report.title),
      message: userRedactedFields.contains('message')
          ? redactedMarker
          : report.message,
      appVersion: maskIf('appVersion', report.appVersion),
      platform: maskIf('platform', report.platform),
      locale: maskIf('locale', report.locale),
      deviceInfo: deviceInfo,
      userRedactedFields: mergedPaths,
    );
  }
}
