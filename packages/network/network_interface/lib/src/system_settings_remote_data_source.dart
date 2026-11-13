import 'package:models/domain.dart';

/// Remote data source for the admin server settings screen (#807).
///
/// The server keeps one settings row. There is no local copy: the screen reads
/// through this each time it opens.
///
/// Implementations run over a **per-server** authenticated transport, like
/// [DataGatewayRemoteDataSource]: the injected client carries the base URL and
/// the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/system-settings`, all under the `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetch] | `GET /api/system-settings` | `{ settings: {...} }` |
/// | [update] | `PATCH /api/system-settings/:id` | the changed fields; `{ settings: {...} }` |
/// | [sendMailTest] | `POST /api/system-settings/mail-test` | 202 `{ queued: true }`. The body isn't read |
///
/// The coded failures below arrive as `{ code, message }` with no `statusCode`
/// or `error`, so an implementation reads the `code` whatever the envelope.
///
/// ## Failures
///
/// - [SystemSettingsForbiddenException]: an enveloped 403 on any route.
/// - [SmtpPasswordRequiredException]: 400 with code `SMTP_PASSWORD_REQUIRED`
///   from [update]. The patch moved the mail server without a password.
/// - [MailNotConfiguredException]: 409 with code `MAIL_NOT_CONFIGURED` from
///   [sendMailTest].
/// - [MailQueueUnavailableException]: 503 with code `MAIL_QUEUE_UNAVAILABLE`
///   from [sendMailTest].
/// - [SystemSettingsTransientException] and
///   [SystemSettingsPermanentException]: the shared rules.
/// - [ArgumentError], unwrapped, from [update]: an empty patch, a
///   [SmtpSecurity.unknown] or [ProviderLinkingPolicy.unknown] in it, a
///   host, user, password or From longer than [maxMailSettingLength] by
///   `serverStringLength`, a port outside `minPort..maxPort`, or a link
///   lifetime outside `minLinkLifetimeMinutes..maxLinkLifetimeMinutes`.
abstract class SystemSettingsRemoteDataSource {
  /// The longest host, user, password or From address the server takes.
  static const int maxMailSettingLength = 255;

  /// The lowest SMTP port the server takes.
  static const int minPort = 1;

  /// The highest SMTP port the server takes.
  static const int maxPort = 65535;

  /// The shortest password reset link lifetime, in minutes.
  static const int minLinkLifetimeMinutes = 15;

  /// The longest password reset link lifetime, in minutes.
  static const int maxLinkLifetimeMinutes = 10080;

  /// The server's settings.
  Future<SystemSettings> fetch();

  /// Applies [patch] to the settings row [id] and returns the stored result.
  ///
  /// Throws [ArgumentError] for an invalid [patch], before any request, and
  /// [SmtpPasswordRequiredException] when the server wants a password with it.
  Future<SystemSettings> update(String id, SystemSettingsPatch patch);

  /// Queues a test email through the saved mail settings.
  ///
  /// Throws [MailNotConfiguredException] when no mail server is set up, and
  /// [MailQueueUnavailableException] when the mail queue is down. The result
  /// of the delivery itself arrives later, as a [MailTestResult].
  Future<void> sendMailTest();
}

/// Base class for every server settings remote failure.
sealed class SystemSettingsRemoteException implements Exception {
  const SystemSettingsRemoteException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      // toString names the concrete subclass, so it needs the runtime type.
      // ignore: no_runtimetype_tostring
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The caller's role may not do this: a 403 from the API itself.
final class SystemSettingsForbiddenException
    extends SystemSettingsRemoteException {
  const SystemSettingsForbiddenException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A 400 with code `SMTP_PASSWORD_REQUIRED`: the patch moved the mail server
/// and no password is stored or sent with it.
final class SmtpPasswordRequiredException
    extends SystemSettingsRemoteException {
  const SmtpPasswordRequiredException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A 409 with code `MAIL_NOT_CONFIGURED`: there is no mail server to send
/// through.
final class MailNotConfiguredException extends SystemSettingsRemoteException {
  const MailNotConfiguredException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A 503 with code `MAIL_QUEUE_UNAVAILABLE`: the server could not queue the
/// email.
final class MailQueueUnavailableException
    extends SystemSettingsRemoteException {
  const MailQueueUnavailableException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The server refused the request, and sending it again will not change that.
final class SystemSettingsPermanentException
    extends SystemSettingsRemoteException {
  const SystemSettingsPermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class SystemSettingsTransientException
    extends SystemSettingsRemoteException {
  const SystemSettingsTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
