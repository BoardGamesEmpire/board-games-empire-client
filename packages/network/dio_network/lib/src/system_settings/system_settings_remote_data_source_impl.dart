import 'package:dio/dio.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:dio_network/src/network/remote_failure.dart';
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
      status == 503 && apiErrorField(body, 'code') == _queueUnavailableCode;

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
    Object? read(SettingValue<String> value) => switch (value) {
      SettingSet<String>(:final value) => value,
      SettingClear<String>() => null,
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

  /// The coded refusals arrive as `{ code, message }` with no envelope, so the
  /// code is read whatever [RemoteRefusal.fromApi] says. A 403 needs the
  /// envelope: without it the shared rules already called it not the API, and
  /// it never reaches here. A retryable 409 never reaches here either.
  @override
  SystemSettingsRemoteException? refused(RemoteRefusal refusal) {
    final status = refusal.status;
    final code = apiErrorField(refusal.body, 'code');
    final message = refusal.message;
    final cause = refusal.cause;
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
    if (status == 403 && refusal.fromApi) {
      return SystemSettingsForbiddenException(
        message,
        statusCode: status,
        cause: cause,
      );
    }
    return null;
  }
}
