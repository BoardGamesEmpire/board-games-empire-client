import 'package:dio/dio.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:dio_network/src/network/request_guards.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [SystemSettingsRemoteDataSource] over a **per-server** Dio instance (#807).
///
/// Built like `AdminHouseholdRemoteDataSourceImpl`: the body is asked for as a
/// `String`, `sendForJson` decodes it after the status is read, and a failure
/// is classified through [_SystemSettingsFailures]. It does not build or own
/// its Dio.
///
/// Failure taxonomy per the [SystemSettingsRemoteDataSource] contract.
class SystemSettingsRemoteDataSourceImpl
    implements SystemSettingsRemoteDataSource {
  const SystemSettingsRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _path = '/api/system-settings';
  static const String _mailTestPath = '/api/system-settings/mail-test';
  static const String _queueUnavailableCode = 'MAIL_QUEUE_UNAVAILABLE';
  static const _failures = _SystemSettingsFailures();

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<SystemSettings> fetch() async {
    const action = 'Server settings fetch';
    final response = await sendForJson(
      () => _dio.get<String>(_path, options: _plainBody),
      action: action,
      family: _failures,
    );
    return parseRemote(
      _failures,
      () => _mapSettings(response.body),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<SystemSettings> update(String id, SystemSettingsPatch patch) async {
    checkPathId(id);
    // Every check runs before the first `wireName`, so an unknown enum is an
    // ArgumentError and never the StateError its wire name throws.
    _validate(patch);

    const action = 'Server settings update';
    final response = await sendForJson(
      () => _dio.patch<String>(
        '$_path/${Uri.encodeComponent(id)}',
        data: _bodyOf(patch),
        options: _plainBody,
      ),
      action: action,
      family: _failures,
    );
    return parseRemote(
      _failures,
      () => _mapSettings(response.body),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<void> sendMailTest() async {
    const action = 'Server mail test';
    // A 503 never reaches the family's `refused` hook, so the one coded 503 is
    // read here, whether Dio returned the response or threw it.
    final Response<String> response;
    try {
      response = await _dio.post<String>(_mailTestPath, options: _plainBody);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != null && _isQueueUnavailable(status, error.response?.data)) {
        throw MailQueueUnavailableException(
          '$action failed with status $status',
          statusCode: status,
          cause: error,
        );
      }
      throw failureForDioException(_failures, error, action: action);
    } on Object catch (error) {
      throw _failures.transient('$action failed unexpectedly', cause: error);
    }

    final status = response.statusCode;
    if (status == null) {
      throw _failures.transient('$action returned no status');
    }
    if (status >= 200 && status < 300) return;
    if (_isQueueUnavailable(status, response.data)) {
      throw MailQueueUnavailableException(
        '$action returned $status',
        statusCode: status,
      );
    }
    throw failureForStatus(
      _failures,
      status,
      '$action returned $status',
      body: response.data,
      cause: null,
    );
  }

  static bool _isQueueUnavailable(int status, Object? body) =>
      status == 503 &&
      isApiErrorEnvelope(body, status) &&
      apiErrorField(body, 'code') == _queueUnavailableCode;

  static void _validate(SystemSettingsPatch patch) {
    if (patch.isEmpty) {
      throw ArgumentError.value(patch, 'patch', 'changes nothing');
    }
    if (patch.smtpSecurity == SmtpSecurity.unknown) {
      throw ArgumentError.value(
        patch.smtpSecurity,
        'patch.smtpSecurity',
        'has no wire name',
      );
    }
    if (patch.providerLinkingPolicy == ProviderLinkingPolicy.unknown) {
      throw ArgumentError.value(
        patch.providerLinkingPolicy,
        'patch.providerLinkingPolicy',
        'has no wire name',
      );
    }
    for (final (name, value) in [
      ('smtpHost', patch.smtpHost),
      ('smtpUser', patch.smtpUser),
      ('smtpPassword', patch.smtpPassword),
      ('mailFromAddress', patch.mailFromAddress),
    ]) {
      if (value is SettingSet<String> &&
          serverStringLength(value.value) >
              SystemSettingsRemoteDataSource.maxMailSettingLength) {
        throw ArgumentError.value(
          name,
          'patch.$name',
          'is longer than '
              '${SystemSettingsRemoteDataSource.maxMailSettingLength} '
              'characters',
        );
      }
    }
    final port = patch.smtpPort;
    if (port != null &&
        (port < SystemSettingsRemoteDataSource.minPort ||
            port > SystemSettingsRemoteDataSource.maxPort)) {
      throw ArgumentError.value(
        port,
        'patch.smtpPort',
        'must be between ${SystemSettingsRemoteDataSource.minPort} and '
            '${SystemSettingsRemoteDataSource.maxPort}',
      );
    }
    final name = patch.name?.trim();
    if (name != null &&
        (name.isEmpty ||
            serverStringLength(name) >
                SystemSettingsRemoteDataSource.maxNameLength)) {
      throw ArgumentError.value(
        patch.name,
        'patch.name',
        'must be 1 to ${SystemSettingsRemoteDataSource.maxNameLength} '
            'characters once trimmed',
      );
    }
    final auditDays = patch.auditLogRetentionDays;
    for (final (field, days) in [
      ('feedbackReportRetentionDays', patch.feedbackReportRetentionDays),
      ('contributionReclaimDays', patch.contributionReclaimDays),
      (
        'auditLogRetentionDays',
        switch (auditDays) {
          SettingSet<int>(:final value) => value,
          _ => null,
        },
      ),
    ]) {
      if (days != null &&
          (days < SystemSettingsRemoteDataSource.minDays ||
              days > SystemSettingsRemoteDataSource.maxDays)) {
        throw ArgumentError.value(
          days,
          'patch.$field',
          'must be between ${SystemSettingsRemoteDataSource.minDays} and '
              '${SystemSettingsRemoteDataSource.maxDays}',
        );
      }
    }
    for (final (field, policy) in [
      ('householdInviteePolicy', patch.householdInviteePolicy),
      ('eventInviteePolicy', patch.eventInviteePolicy),
    ]) {
      if (policy != null &&
          !SystemSettingsRemoteDataSource.inviteePolicies.contains(policy)) {
        throw ArgumentError.value(
          policy,
          'patch.$field',
          'is not a policy the server takes',
        );
      }
    }
    final lifetime = patch.passwordResetLinkLifetimeMinutes;
    if (lifetime != null &&
        (lifetime < SystemSettingsRemoteDataSource.minLinkLifetimeMinutes ||
            lifetime > SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes)) {
      throw ArgumentError.value(
        lifetime,
        'patch.passwordResetLinkLifetimeMinutes',
        'must be between '
            '${SystemSettingsRemoteDataSource.minLinkLifetimeMinutes} and '
            '${SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes}',
      );
    }
  }

  /// Only the fields the patch changes: a [SettingClear] is JSON `null`.
  static Map<String, Object?> _bodyOf(SystemSettingsPatch patch) {
    Object? read<T extends Object>(SettingValue<T> value) => switch (value) {
      SettingSet<T>(:final value) => value,
      SettingClear<T>() => null,
    };
    return {
      if (patch.smtpHost case final value?) 'smtpHost': read(value),
      'smtpPort': ?patch.smtpPort,
      if (patch.smtpSecurity case final value?) 'smtpSecurity': value.wireName,
      if (patch.smtpUser case final value?) 'smtpUser': read(value),
      if (patch.smtpPassword case final value?) 'smtpPassword': read(value),
      if (patch.mailFromAddress case final value?)
        'mailFromAddress': read(value),
      'passwordResetLinkLifetimeMinutes':
          ?patch.passwordResetLinkLifetimeMinutes,
      'allowPasswordResets': ?patch.allowPasswordResets,
      if (patch.providerLinkingPolicy case final value?)
        'providerLinkingPolicy': value.wireName,
      // The server trims the name, so it goes as given.
      'name': ?patch.name,
      'allowUserRegistration': ?patch.allowUserRegistration,
      'allowUsernameChange': ?patch.allowUsernameChange,
      'feedbackReportRetentionDays': ?patch.feedbackReportRetentionDays,
      'feedbackReportServerRedactionEnabled':
          ?patch.feedbackReportServerRedactionEnabled,
      'requireContributionApproval': ?patch.requireContributionApproval,
      'contributionReclaimDays': ?patch.contributionReclaimDays,
      if (patch.auditLogRetentionDays case final value?)
        'auditLogRetentionDays': read(value),
      if (patch.householdInviteePolicy case final value?)
        'householdInviteePolicy': value.toWire(),
      if (patch.eventInviteePolicy case final value?)
        'eventInviteePolicy': value.toWire(),
    };
  }

  /// Reads `{ settings: {...} }`, taking only the fields [SystemSettings]
  /// has.
  static SystemSettings _mapSettings(Map<String, dynamic> body) {
    final json = body['settings'];
    if (json is! Map<String, dynamic>) {
      throw FormatException(
        json == null
            ? 'response is missing the "settings" object'
            : 'response field "settings" is ${json.runtimeType}, expected '
                  'an object',
      );
    }
    final passwordSet = json['smtpPasswordSet'];
    if (passwordSet is! bool) {
      throw FormatException(
        'settings "smtpPasswordSet" is ${passwordSet.runtimeType}, expected '
        'a bool',
      );
    }
    return SystemSettings(
      id: json['id'] as String,
      smtpHost: json['smtpHost'] as String?,
      smtpPort: json['smtpPort'] as int,
      smtpSecurity: SmtpSecurity.fromWire(json['smtpSecurity'] as String),
      smtpUser: json['smtpUser'] as String?,
      smtpPasswordSet: passwordSet,
      mailFromAddress: json['mailFromAddress'] as String?,
      passwordResetLinkLifetimeMinutes:
          json['passwordResetLinkLifetimeMinutes'] as int,
      allowPasswordResets: json['allowPasswordResets'] as bool,
      providerLinkingPolicy: ProviderLinkingPolicy.fromWire(
        json['providerLinkingPolicy'] as String,
      ),
      name: json['name'] as String,
      allowUserRegistration: json['allowUserRegistration'] as bool,
      allowUsernameChange: json['allowUsernameChange'] as bool,
      feedbackReportRetentionDays: json['feedbackReportRetentionDays'] as int,
      feedbackReportServerRedactionEnabled:
          json['feedbackReportServerRedactionEnabled'] as bool,
      requireContributionApproval: json['requireContributionApproval'] as bool,
      contributionReclaimDays: json['contributionReclaimDays'] as int,
      auditLogRetentionDays: json['auditLogRetentionDays'] as int?,
      householdInviteePolicy: Reach.fromWire(
        json['householdInviteePolicy'] as String,
      ),
      eventInviteePolicy: Reach.fromWire(json['eventInviteePolicy'] as String),
    );
  }
}

/// How the server settings source builds its failures for the shared
/// classifier.
final class _SystemSettingsFailures
    extends RemoteFailureFamily<SystemSettingsRemoteException> {
  const _SystemSettingsFailures()
    : super(
        transient: SystemSettingsTransientException.new,
        permanent: SystemSettingsPermanentException.new,
      );

  /// The coded refusals arrive in the API's error envelope,
  /// `{ statusCode, error, message, code }` (backend#1260), so a code is read
  /// only when [RemoteRefusal.fromApi] says the body is the API's. A bare coded
  /// body is not the API's. A retryable 409 never reaches here.
  @override
  SystemSettingsRemoteException? refused(RemoteRefusal refusal) {
    final status = refusal.status;
    final code = apiErrorField(refusal.body, 'code');
    final message = refusal.message;
    final cause = refusal.cause;
    if (!refusal.fromApi) return null;
    if (status == 400 && code == 'SMTP_PASSWORD_REQUIRED') {
      return SmtpPasswordRequiredException(
        message,
        statusCode: status,
        cause: cause,
      );
    }
    if (status == 409 && code == 'MAIL_NOT_CONFIGURED') {
      return MailNotConfiguredException(
        message,
        statusCode: status,
        cause: cause,
      );
    }
    if (status == 403) {
      return SystemSettingsForbiddenException(
        message,
        statusCode: status,
        cause: cause,
      );
    }
    return null;
  }
}
