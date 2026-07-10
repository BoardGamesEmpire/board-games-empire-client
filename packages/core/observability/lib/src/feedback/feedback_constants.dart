/// Client-side mirrors of the backend feedback transport/protocol caps.
///
/// Source of truth:
/// `libs/api/feedback/src/lib/constants/feedback.constants.ts` in
/// `board-games-empire-backend`. These are compile-time protocol limits
/// (runtime-tunable policy like retention lives in the backend's
/// SystemSetting); the client validates against them BEFORE submission so
/// over-cap reports fail fast and offline-queued reports are never
/// rejected hours later on sync.
abstract final class FeedbackConstants {
  /// 256 KB transport-layer body cap (backend body-parser limit).
  static const int maxBodyBytes = 256 * 1024;

  /// Field-level cap on `message`.
  static const int maxMessageLength = 10000;

  /// Field-level cap on the dedicated `stackTrace` field (backend #77).
  /// The client truncates to this; the backend rejects anything past it
  /// (no server-side truncation).
  static const int maxStackTraceLength = 32768;

  /// Field-level cap on `title`.
  static const int maxTitleLength = 200;

  /// Field-level cap on `appVersion`.
  static const int maxAppVersionLength = 64;

  /// Field-level cap on `platform`.
  static const int maxPlatformLength = 32;

  /// Field-level cap on `locale`.
  static const int maxLocaleLength = 32;

  /// Field-level cap on `correlationKey`.
  static const int maxCorrelationKeyLength = 128;

  /// Cap on the `userRedactedFields` array length.
  static const int maxRedactedFields = 64;

  /// Cap on the serialized (UTF-8) `breadcrumbs` array (backend #86,
  /// enforced by the backend's `@MaxJsonBytes`). Measured over the same
  /// JSON encoding the transport sends, so the client's build-time
  /// trimming and [FeedbackConstants]-based validation agree with the
  /// server's check.
  static const int maxBreadcrumbsBytes = 65536;
}
