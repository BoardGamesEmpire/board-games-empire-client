import 'package:dio/dio.dart';
import 'package:dio_network/src/api_key/api_key_json.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:dio_network/src/network/json_reads.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:dio_network/src/network/request_guards.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [ApiKeyRemoteDataSource] over a **per-server** Dio instance (#1028).
///
/// Every request asks Dio for the body as a `String` with the response type
/// pinned, and `sendForJson` decodes it once the status is read and files a
/// failure through [_ApiKeyFailures]. It does not build or own its Dio; the
/// network installer constructs it from the per-server container.
///
/// The secret in a create's answer is read into the returned
/// [CreatedApiKey] and goes nowhere else: no failure built here carries a
/// request or response body.
///
/// Failure taxonomy per the [ApiKeyRemoteDataSource] contract.
class ApiKeyRemoteDataSourceImpl implements ApiKeyRemoteDataSource {
  const ApiKeyRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _path = '/api/api-keys';

  /// See `DataGatewayRemoteDataSourceImpl._plainBody`.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<List<GrantablePermission>> fetchGrantable() async {
    const failures = _ApiKeyFailures();
    return sendForParsed(
      () => _dio.get<String>('$_path/grantable', options: _plainBody),
      action: 'API key permissions',
      family: failures,
      map: (body) {
        final permissions = body['permissions'];
        if (permissions is! List) {
          throw FormatException(
            '"permissions" is ${permissions.runtimeType}, expected a list',
          );
        }
        return [
          for (final permission in permissions)
            grantablePermissionFromJson(
              requireObject(permission, 'permissions[]'),
            ),
        ];
      },
    );
  }

  @override
  Future<PaginatedResult<ApiKey>> fetchPage({
    int page = 1,
    int limit = ApiKeyRemoteDataSource.defaultPageSize,
  }) async {
    checkPage(
      page: page,
      limit: limit,
      maxSize: ApiKeyRemoteDataSource.maxPageSize,
      maxDepth: serverMaxPageDepth,
    );

    const failures = _ApiKeyFailures();
    return sendForParsed(
      () => _dio.get<String>(
        _path,
        options: _plainBody,
        queryParameters: {'page': page, 'limit': limit},
      ),
      action: 'API key list',
      family: failures,
      map: (body) => PaginatedResult.fromEnvelope(
        body,
        key: 'apiKeys',
        item: apiKeyFromJson,
      ),
    );
  }

  @override
  Future<ApiKey> fetch(String id) async {
    checkPathId(id);

    const failures = _ApiKeyFailures();
    return sendForParsed(
      () => _dio.get<String>(_row(id), options: _plainBody),
      action: 'API key read',
      family: failures,
      map: (body) => apiKeyFromJson(requireObject(body['apiKey'], 'apiKey')),
    );
  }

  @override
  Future<CreatedApiKey> create(ApiKeyCreate request) async {
    final name = _checkedName(request.name);
    _checkExpiry(request.expiresInDays, name: 'request.expiresInDays');
    final grant = request.grant;
    if (grant is ApiKeyScopesGrant) {
      _checkScopes(grant.scopes, name: 'request.grant');
    }

    const failures = _ApiKeyFailures();
    return sendForParsed(
      () => _dio.post<String>(
        _path,
        options: _plainBody,
        data: <String, Object?>{
          'name': name,
          ...switch (grant) {
            ApiKeyScopesGrant(:final scopes) => {
              'scopes': [for (final scope in scopes) apiKeyScopeToJson(scope)],
            },
            ApiKeyEverythingGrant() => {'preset': 'everything'},
          },
          'expiresInDays': request.expiresInDays,
          if (request.confirmCritical) 'confirmCritical': true,
        },
      ),
      action: 'API key create',
      family: failures,
      map: (body) {
        final apiKey = apiKeyFromJson(requireObject(body['apiKey'], 'apiKey'));
        final secret = body['secret'];
        if (secret is! String || secret.isEmpty) {
          // The type, never the value.
          throw FormatException(
            '"secret" is ${secret.runtimeType}, expected a non-empty string',
          );
        }
        return CreatedApiKey(apiKey: apiKey, secret: secret);
      },
    );
  }

  @override
  Future<ApiKey> update(String id, ApiKeyPatch patch) async {
    checkPathId(id);
    if (patch.isEmpty) {
      throw ArgumentError.value(patch, 'patch', 'has nothing to change');
    }
    final name = patch.name == null ? null : _checkedName(patch.name!);
    final expiresInDays = patch.expiresInDays;
    if (expiresInDays != null) {
      _checkExpiry(expiresInDays, name: 'patch.expiresInDays');
    }
    final scopes = patch.scopes;
    if (scopes != null) {
      _checkScopes(scopes, name: 'patch.scopes');
    }

    const failures = _ApiKeyFailures();
    return sendForParsed(
      () => _dio.patch<String>(
        _row(id),
        options: _plainBody,
        data: <String, Object?>{
          'name': ?name,
          'enabled': ?patch.enabled,
          if (scopes != null)
            'scopes': [for (final scope in scopes) apiKeyScopeToJson(scope)],
          'expiresInDays': ?expiresInDays,
          if (patch.confirmCritical) 'confirmCritical': true,
        },
      ),
      action: 'API key update',
      family: failures,
      map: (body) => apiKeyFromJson(requireObject(body['apiKey'], 'apiKey')),
    );
  }

  @override
  Future<void> delete(String id) async {
    checkPathId(id);

    const failures = _ApiKeyFailures();
    await sendForJson(
      () => _dio.delete<String>(_row(id), options: _plainBody),
      action: 'API key delete',
      family: failures,
      // The answer is `{ message }`, which nothing here needs.
      readBody: false,
    );
  }

  static String _row(String id) => '$_path/${Uri.encodeComponent(id)}';

  /// The name as the server will read it: trimmed, and 1 to
  /// [ApiKeyRemoteDataSource.maxNameLength] units of Dart `String.length`.
  static String _checkedName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.length > ApiKeyRemoteDataSource.maxNameLength) {
      throw ArgumentError.value(
        name,
        'name',
        'must be 1 to ${ApiKeyRemoteDataSource.maxNameLength} characters '
            'after trimming',
      );
    }
    return trimmed;
  }

  static void _checkExpiry(int days, {required String name}) {
    if (days < ApiKeyRemoteDataSource.minExpiryDays ||
        days > ApiKeyRemoteDataSource.maxExpiryDays) {
      throw ArgumentError.value(
        days,
        name,
        'must be ${ApiKeyRemoteDataSource.minExpiryDays} to '
        '${ApiKeyRemoteDataSource.maxExpiryDays} days',
      );
    }
  }

  /// A slug and a pin the server would refuse with a 400. An unpinned scope
  /// has a null `resourceId`: an empty one is never what was meant.
  static void _checkScopes(List<ApiKeyScope> scopes, {required String name}) {
    for (final scope in scopes) {
      if (scope.slug.isEmpty || scope.resourceId?.isEmpty == true) {
        throw ArgumentError.value(
          scopes,
          name,
          'a scope needs a slug, and a pin is left out rather than empty',
        );
      }
    }
  }
}

/// How the API key source builds its failures for the shared classifier.
final class _ApiKeyFailures extends RemoteFailureFamily<ApiKeyRemoteException> {
  const _ApiKeyFailures()
    : super(
        transient: ApiKeyTransientException.new,
        permanent: ApiKeyPermanentException.new,
      );

  /// The coded refusals arrive in the API's error envelope, `{ statusCode,
  /// error, message, code, ...fields }`, so a code is read only when
  /// [RemoteRefusal.fromApi] says the body is the API's. A coded body without
  /// the envelope is not the API's and takes the shared default.
  ///
  /// Every refusal from the API carries its `message`, as
  /// [ApiKeyRemoteException.apiMessage]. That includes a 400 validation error,
  /// whose `message` may be a list of strings, and any other enveloped 4xx,
  /// which is permanent.
  ///
  /// An enveloped 404 is "not found" only with the code
  /// `API_KEY_NOT_FOUND`: Nest answers an unmatched route with an enveloped
  /// 404 too, under another code, and that stays transient (#297).
  @override
  ApiKeyRemoteException? refused(RemoteRefusal refusal) {
    if (!refusal.fromApi) return null;

    final status = refusal.status;
    final body = refusal.body;
    final message = refusal.message;
    final cause = refusal.cause;
    final apiMessage = _apiMessage(body);

    return switch ((status, apiErrorField(body, 'code'))) {
      (403, 'API_KEY_NEEDS_RECENT_SIGN_IN') => ApiKeyNeedsRecentSignInException(
        message,
        statusCode: status,
        cause: cause,
        apiMessage: apiMessage,
      ),
      (403, 'API_KEY_SESSION_REQUIRED') => ApiKeySessionRequiredException(
        message,
        statusCode: status,
        cause: cause,
        apiMessage: apiMessage,
      ),
      (404, 'API_KEY_NOT_FOUND') => ApiKeyNotFoundException(
        message,
        statusCode: status,
        cause: cause,
        apiMessage: apiMessage,
      ),
      // An enveloped 404 under any other code is the route missing.
      (404, _) => null,
      (422, 'API_KEY_CRITICAL_NEEDS_CONFIRMATION') =>
        ApiKeyCriticalNeedsConfirmationException(
          message,
          statusCode: status,
          cause: cause,
          apiMessage: apiMessage,
        ),
      (422, 'API_KEY_SCOPE_NOT_GRANTABLE') => ApiKeyScopeNotGrantableException(
        message,
        statusCode: status,
        cause: cause,
        apiMessage: apiMessage,
        slug: apiErrorField(body, 'slug'),
      ),
      (422, 'API_KEY_SCOPE_NOT_PINNABLE') => ApiKeyScopeNotPinnableException(
        message,
        statusCode: status,
        cause: cause,
        apiMessage: apiMessage,
        slug: apiErrorField(body, 'slug'),
      ),
      (422, 'API_KEY_EXPIRY_OUT_OF_RANGE') => ApiKeyExpiryOutOfRangeException(
        message,
        statusCode: status,
        cause: cause,
        apiMessage: apiMessage,
        min: _intField(body, 'min'),
        max: _intField(body, 'max'),
      ),
      // The rest are permanent as the shared default has them, with the
      // server's words kept: a 400 validation error, `API_KEY_SCOPES_OR_PRESET`
      // and any other enveloped 4xx.
      _ => ApiKeyPermanentException(
        message,
        statusCode: status,
        cause: cause,
        apiMessage: apiMessage,
      ),
    };
  }

  /// The envelope's `message`. A validation error from Nest may carry a list
  /// of strings there, one per field, and `apiErrorField` drops a list, so
  /// the strings are joined one to a line. A message that is neither is null.
  static String? _apiMessage(Object? body) {
    final single = apiErrorField(body, 'message');
    if (single != null) return single.isEmpty ? null : single;

    final decoded = probeJsonBody(body);
    if (decoded is! Map) return null;
    final value = decoded['message'];
    if (value is! List) return null;
    final lines = value.whereType<String>().where((line) => line.isNotEmpty);
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// The whole number [field] of an error body, or null.
  static int? _intField(Object? body, String field) {
    final decoded = probeJsonBody(body);
    if (decoded is! Map) return null;
    final value = decoded[field];
    return value is int ? value : null;
  }
}
