import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/decode_json_body.dart';

/// [DataGatewayRemoteDataSource] over a **per-server** Dio instance (#41).
///
/// Built on the collection source's request plumbing (#351): the body is asked
/// for as a `String` with the response type pinned on every request, decoded
/// here after the status is read, and probed for the API's error envelope with
/// a bounded synchronous parse. Like that source, it does not build or own its
/// Dio; the network installer constructs it from the per-server container.
///
/// Failure taxonomy per the [DataGatewayRemoteDataSource] contract.
class DataGatewayRemoteDataSourceImpl implements DataGatewayRemoteDataSource {
  const DataGatewayRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _basePath = '/api/data-gateways';

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  /// 4xx statuses worth retrying: an expired session (401), proxy
  /// authentication (407), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 407, 408, 429};

  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) async {
    _checkPaging(page: page, limit: limit);

    const action = 'DataGateway list';
    final response = await _send(
      request: () => _dio.get<String>(
        _basePath,
        options: _plainBody,
        queryParameters: {'page': page, 'limit': limit},
      ),
      action: action,
      // A list route is never absent for a caller who reached it: an empty
      // list is a 200. So a 404 here means the route is not deployed, such as
      // a server older than backend#710's rename.
      rowRoute: false,
    );

    return _parse(
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'dataGateways',
        item: _mapDataGateway,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<DataGateway> fetchOne(String id) async {
    const action = 'DataGateway fetch';
    final response = await _send(
      request: () => _dio.get<String>(_pathOf(id), options: _plainBody),
      action: action,
      rowRoute: true,
    );
    return _parse(
      () => _mapDataGateway(_dataGatewayObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<DataGatewayChangeResult> create(DataGatewayInput input) async {
    _checkPort(input.connectionPort);

    const action = 'DataGateway create';
    final response = await _send(
      request: () => _dio.post<String>(
        _basePath,
        options: _plainBody,
        data: {
          'name': input.name,
          'connectionUrl': input.connectionUrl,
          'connectionPort': input.connectionPort,
          // The one auth type that connects today. The others throw on the
          // server's connect path, so the client offers none of them and sends
          // no credentials (#41).
          'authType': DataGatewayAuthType.none.toWire(),
          'description': ?input.description,
        },
      ),
      action: action,
      rowRoute: false,
    );
    return _changeResult(response, action: action);
  }

  @override
  Future<DataGatewayChangeResult> update(
    String id,
    DataGatewayChanges changes,
  ) async {
    if (changes.isEmpty) {
      throw ArgumentError.value(
        changes,
        'changes',
        'at least one field must change; the server refuses an empty update '
            'with a 400',
      );
    }
    final port = changes.connectionPort;
    if (port != null) _checkPort(port);

    final description = changes.description;
    final body = <String, dynamic>{
      'name': ?changes.name,
      'connectionUrl': ?changes.connectionUrl,
      'connectionPort': ?port,
      // An empty description is the edit form's "clear it". On this route an
      // explicit null clears the column, so that is what is sent.
      if (description != null)
        'description': description.isEmpty ? null : description,
    };

    const action = 'DataGateway update';
    final response = await _send(
      request: () =>
          _dio.patch<String>(_pathOf(id), options: _plainBody, data: body),
      action: action,
      rowRoute: true,
    );
    return _changeResult(response, action: action);
  }

  @override
  Future<DataGatewayChangeResult> delete(String id) async {
    const action = 'DataGateway delete';
    final response = await _send(
      request: () => _dio.delete<String>(_pathOf(id), options: _plainBody),
      action: action,
      rowRoute: true,
    );
    return _changeResult(response, action: action);
  }

  @override
  Future<DataGatewayChangeResult> connect(String id) async {
    const action = 'DataGateway connect';
    final response = await _send(
      request: () =>
          _dio.post<String>('${_pathOf(id)}/connect', options: _plainBody),
      action: action,
      rowRoute: true,
    );
    return _changeResult(response, action: action);
  }

  @override
  Future<DataGatewayChangeResult> disconnect(String id) async {
    const action = 'DataGateway disconnect';
    final response = await _send(
      request: () =>
          _dio.post<String>('${_pathOf(id)}/disconnect', options: _plainBody),
      action: action,
      rowRoute: true,
    );
    return _changeResult(response, action: action);
  }

  static String _pathOf(String id) => '$_basePath/${Uri.encodeComponent(id)}';

  // ── Request plumbing ────────────────────────────────────────────────

  /// Sends [request] and returns its decoded body, having converted every
  /// failure into a [DataGatewayRemoteException].
  ///
  /// [rowRoute] says whether the path names one DataGateway, which is what
  /// lets an application 404 mean that row is gone.
  Future<({Map<String, dynamic> body, int status})> _send({
    required Future<Response<String>> Function() request,
    required String action,
    required bool rowRoute,
  }) async {
    late final Response<String> response;
    try {
      response = await request();
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action, rowRoute: rowRoute);
    } on Object catch (error) {
      // Nothing else should escape Dio. `Object`, not `Exception`, so an
      // `Error` cannot break the "no raw transport error" promise either.
      throw DataGatewayTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw DataGatewayTransientException('$action returned no status');
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(
        status,
        '$action returned $status',
        cause: null,
        rowRoute: rowRoute,
        body: response.data,
      );
    }

    final raw = response.data;
    if (raw == null || raw.isEmpty) {
      throw DataGatewayPermanentException(
        '$action returned an empty body',
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = await decodeJsonBody(raw);
    } on FormatException catch (error) {
      throw DataGatewayPermanentException(
        '$action returned a body that is not JSON',
        statusCode: status,
        cause: error,
      );
    } on Object catch (error) {
      // The decode could not run (an isolate that would not spawn), which
      // says nothing about the response. See the collection source (#297).
      throw DataGatewayTransientException(
        '$action could not be decoded',
        statusCode: status,
        cause: error,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw DataGatewayPermanentException(
        '$action returned a body that is not a JSON object',
        statusCode: status,
      );
    }
    return (body: decoded, status: status);
  }

  /// A 2xx whose body cannot be mapped is permanent: the same request returns
  /// the same body.
  T _parse<T>(T Function() map, {required String action, required int status}) {
    try {
      return map();
    } on Object catch (error) {
      throw DataGatewayPermanentException(
        'Failed to parse the $action response: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  /// Reads `{ dataGateway, connection_* | disconnection_* }`, the body every
  /// change route answers with.
  DataGatewayChangeResult _changeResult(
    ({Map<String, dynamic> body, int status}) response, {
    required String action,
  }) => _parse(
    () {
      final body = response.body;
      return DataGatewayChangeResult(
        dataGateway: _mapDataGateway(_dataGatewayObject(body)),
        connectionAttempt:
            _attempt(
              body,
              attemptKey: 'connection_attempt',
              responseKey: 'connection_response',
              action: DataGatewayConnectionAction.connect,
            ) ??
            _attempt(
              body,
              attemptKey: 'disconnection_attempt',
              responseKey: 'disconnection_response',
              action: DataGatewayConnectionAction.disconnect,
            ),
      );
    },
    action: action,
    status: response.status,
  );

  static Map<String, dynamic> _dataGatewayObject(Map<String, dynamic> body) {
    final row = body['dataGateway'];
    if (row is! Map<String, dynamic>) {
      throw const FormatException('response is missing a "dataGateway" object');
    }
    return row;
  }

  /// The attempt [attemptKey] reports, or null when the server made none.
  ///
  /// Only `success` is read. On a failure the server sends a generic,
  /// translated `message` and keeps the coordinator's error in its own log;
  /// the client shows its own words for the outcome instead.
  static DataGatewayConnectionAttempt? _attempt(
    Map<String, dynamic> body, {
    required String attemptKey,
    required String responseKey,
    required DataGatewayConnectionAction action,
  }) {
    if (body[attemptKey] != true) return null;
    final response = body[responseKey];
    if (response is! Map<String, dynamic>) {
      throw FormatException(
        '"$attemptKey" is true but "$responseKey" is missing',
      );
    }
    return DataGatewayConnectionAttempt(
      action: action,
      succeeded: response['success'] as bool,
    );
  }

  /// Maps a server row to [DataGateway], field by field.
  ///
  /// Explicit rather than generated, so the mapping reads only what the model
  /// holds. In particular it never touches `authParameters` (#41).
  static DataGateway _mapDataGateway(Map<String, dynamic> json) => DataGateway(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    connectionUrl: json['connectionUrl'] as String,
    connectionPort: json['connectionPort'] as int,
    enabled: json['enabled'] as bool,
    authType: DataGatewayAuthType.fromWire(json['authType'] as String),
  );

  // ── Guards: requests the server is guaranteed to reject ─────────────

  void _checkPaging({required int page, required int limit}) {
    const maxPageSize = DataGatewayRemoteDataSource.maxPageSize;
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $maxPageSize (the server rejects a larger '
            'page rather than clamping it)',
      );
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'is 1-based');
    }
  }

  void _checkPort(int port) {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'connectionPort', 'must be 1–65535');
    }
  }

  // ── Failure classification ──────────────────────────────────────────

  DataGatewayRemoteException _classifyDioException(
    DioException error, {
    required String action,
    required bool rowRoute,
  }) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        '$action failed with status $status',
        cause: error,
        rowRoute: rowRoute,
        body: error.response?.data,
      );
    }
    return DataGatewayTransientException('$action failed', cause: error);
  }

  DataGatewayRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
    required bool rowRoute,
    required Object? body,
  }) {
    if (status >= 500 || _retryable4xx.contains(status)) {
      return DataGatewayTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }

    // Every answer below is a conclusion about the caller's role or about a
    // row, and only the application's own envelope licenses one. A proxy or
    // WAF answers 403 and 404 too (#350, #365, #253).
    final fromApi = isApiErrorEnvelope(body, status);

    if (status == 403) {
      return fromApi
          ? DataGatewayForbiddenException(
              message,
              cause: cause,
              statusCode: status,
            )
          : DataGatewayTransientException(
              '$message; the request did not reach the API',
              cause: cause,
              statusCode: status,
            );
    }
    if (status == 404) {
      // Nest answers an unregistered route with this same envelope, so on the
      // list route even an application 404 means "not deployed", not "no
      // rows". On a row route it is the service saying the row is gone.
      return fromApi && rowRoute
          ? DataGatewayNotFoundException(
              message,
              cause: cause,
              statusCode: status,
            )
          : DataGatewayTransientException(
              '$message; the route was not reachable',
              cause: cause,
              statusCode: status,
            );
    }
    if (status == 409 && fromApi) {
      return DataGatewayNameInUseException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status >= 400) {
      return DataGatewayPermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A 1xx or 3xx surfaced by a permissive validateStatus carries no
    // rejection.
    return DataGatewayTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
