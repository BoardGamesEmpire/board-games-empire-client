import 'package:dio/dio.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [DataGatewayRemoteDataSource] over a **per-server** Dio instance (#41).
///
/// The body is asked for as a `String` with the response type pinned on every
/// request, and `sendForJson` decodes it after the status is read and
/// classifies a failure through [_GatewayFailures]. Like the other remote
/// sources, it does not build or own its Dio; the network installer
/// constructs it from the per-server container.
///
/// Failure taxonomy per the [DataGatewayRemoteDataSource] contract.
class DataGatewayRemoteDataSourceImpl implements DataGatewayRemoteDataSource {
  const DataGatewayRemoteDataSourceImpl(this._dio, {this._browser = kIsWeb});

  final Dio _dio;

  /// Whether a browser's adapter carries the requests. See [interviewTimeout].
  final bool _browser;

  static const String _basePath = '/api/data-gateways';

  /// The language catalogue, which belongs to no DataGateway.
  static const String _languagesPath = '/api/languages';

  /// How long an interview may take to answer. The server waits for it and
  /// sets no deadline of its own (backend#722), so the factories' ten seconds
  /// could cut one short.
  ///
  /// In a browser it is the connect timeout as well: with no request body, the
  /// adapter there keeps the connect timer running until response bytes arrive,
  /// so a slow answer surfaces as a connection timeout. Elsewhere the connect
  /// timer stops at the connection, so it keeps the factory's limit, and a
  /// server that can't be reached says so as soon as any other call would.
  static const Duration interviewTimeout = Duration(seconds: 60);

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) async {
    _checkPaging(
      page: page,
      limit: limit,
      ceiling: DataGatewayRemoteDataSource.maxPageSize,
    );

    const action = 'DataGateway list';
    // A list route is never absent for a caller who reached it: an empty list
    // is a 200. So a 404 here means the route is not deployed, such as a
    // server older than backend#710's rename.
    const failures = _GatewayFailures(rowRoute: false);
    final response = await sendForJson(
      () => _dio.get<String>(
        _basePath,
        options: _plainBody,
        queryParameters: {'page': page, 'limit': limit},
      ),
      action: action,
      family: failures,
    );

    return parseRemote(
      failures,
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
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.get<String>(_pathOf(id), options: _plainBody),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapDataGateway(_dataGatewayObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<DataGatewayChangeResult> create(DataGatewayInput input) async {
    _checkPort(input.connectionPort);

    const action = 'DataGateway create';
    const failures = _GatewayFailures(rowRoute: false, conflictIsName: true);
    final response = await sendForJson(
      () => _dio.post<String>(
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
      family: failures,
    );
    return _changeResult(response, action: action, family: failures);
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
    const failures = _GatewayFailures(rowRoute: true, conflictIsName: true);
    final response = await sendForJson(
      () => _dio.patch<String>(_pathOf(id), options: _plainBody, data: body),
      action: action,
      family: failures,
    );
    return _changeResult(response, action: action, family: failures);
  }

  @override
  Future<DataGatewayChangeResult> setDisabledCapabilities(
    String id,
    List<String> disabled,
  ) async {
    const action = 'DataGateway capability update';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.patch<String>(
        _pathOf(id),
        options: _plainBody,
        // The whole list, in the order given: the server replaces its list
        // with this one, so an empty list is how everything is switched back
        // on.
        data: {'disabledCapabilities': disabled},
      ),
      action: action,
      family: failures,
    );
    return _changeResult(response, action: action, family: failures);
  }

  @override
  Future<DataGatewayChangeResult> delete(String id) async {
    const action = 'DataGateway delete';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.delete<String>(_pathOf(id), options: _plainBody),
      action: action,
      family: failures,
    );
    return _changeResult(response, action: action, family: failures);
  }

  @override
  Future<DataGatewayChangeResult> connect(String id) async {
    const action = 'DataGateway connect';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.post<String>('${_pathOf(id)}/connect', options: _plainBody),
      action: action,
      family: failures,
    );
    return _changeResult(response, action: action, family: failures);
  }

  @override
  Future<DataGatewayChangeResult> disconnect(String id) async {
    const action = 'DataGateway disconnect';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.post<String>('${_pathOf(id)}/disconnect', options: _plainBody),
      action: action,
      family: failures,
    );
    return _changeResult(response, action: action, family: failures);
  }

  @override
  Future<DataGatewayInterviewResult> interview(String id) async {
    const action = 'DataGateway interview';
    // The server may keep interviewing after the caller stops waiting.
    final failures = _GatewayFailures(
      rowRoute: true,
      timeoutIsUnknown: true,
      browser: _browser,
    );
    final response = await sendForJson(
      () => _dio.post<String>(
        '${_pathOf(id)}/interview',
        options: _plainBody.copyWith(
          connectTimeout: _browser ? interviewTimeout : null,
          receiveTimeout: interviewTimeout,
        ),
      ),
      action: action,
      family: failures,
    );
    return _interviewResult(response, action: action, family: failures);
  }

  @override
  Future<PaginatedResult<LanguageLink>> fetchLanguageLinks(
    String id, {
    Set<LanguageLinkStatus>? statuses,
    int page = 1,
    int limit = DataGatewayRemoteDataSource.languageLinkPageSize,
  }) async {
    _checkPaging(
      page: page,
      limit: limit,
      ceiling: DataGatewayRemoteDataSource.maxPageSize,
    );
    if (statuses != null && statuses.isEmpty) {
      throw ArgumentError.value(
        statuses,
        'statuses',
        'must name at least one status, or be null for the waiting links; '
            'the server refuses an empty list with a 400',
      );
    }
    // Worked out before the request, so a status that cannot be sent fails the
    // call as it is, and is not reported as a request that failed.
    final wireStatuses = statuses?.map((status) => status.toWire()).join(',');

    const action = 'Language link list';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.get<String>(
        _languageLinksPath(id),
        options: _plainBody,
        queryParameters: {
          'page': page,
          'limit': limit,
          // Left out when no statuses were given, so the server lists the
          // links waiting on a review.
          'status': ?wireStatuses,
        },
      ),
      action: action,
      family: failures,
    );

    return parseRemote(
      failures,
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'languageLinks',
        item: _mapLanguageLink,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<LanguageLink> linkLanguageLink(
    String id,
    String linkId,
    String tagId,
  ) async {
    const action = 'Language link to tag';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.post<String>(
        '${_languageLinkPath(id, linkId)}/link',
        options: _plainBody,
        data: {'tagId': tagId},
      ),
      action: action,
      family: failures,
    );
    return _languageLinkResult(response, action: action, family: failures);
  }

  @override
  Future<LanguageLink> ignoreLanguageLink(String id, String linkId) async {
    const action = 'Language link ignore';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.post<String>(
        '${_languageLinkPath(id, linkId)}/ignore',
        options: _plainBody,
      ),
      action: action,
      family: failures,
    );
    return _languageLinkResult(response, action: action, family: failures);
  }

  @override
  Future<LanguageLink> acceptLanguageLink(String id, String linkId) async {
    const action = 'Language link accept';
    const failures = _GatewayFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.post<String>(
        '${_languageLinkPath(id, linkId)}/accept',
        options: _plainBody,
      ),
      action: action,
      family: failures,
    );
    return _languageLinkResult(response, action: action, family: failures);
  }

  @override
  Future<PaginatedResult<LanguageTagRef>> fetchLanguageTags({
    String? name,
    int page = 1,
    int limit = DataGatewayRemoteDataSource.languageTagPageSize,
  }) async {
    _checkPaging(
      page: page,
      limit: limit,
      ceiling: DataGatewayRemoteDataSource.languageTagPageSize,
    );
    // The server matches the text as sent, so a stray space would match
    // nothing. A blank name filters nothing, so it is left out.
    final filter = name?.trim();

    const action = 'Language tag list';
    // The catalogue belongs to no DataGateway, and a list route is never
    // absent for a caller who reached it, so a 404 here means the route is
    // not deployed.
    const failures = _GatewayFailures(rowRoute: false);
    final response = await sendForJson(
      () => _dio.get<String>(
        _languagesPath,
        options: _plainBody,
        queryParameters: {
          'page': page,
          'limit': limit,
          if (filter != null && filter.isNotEmpty) 'name': filter,
        },
      ),
      action: action,
      family: failures,
    );

    return parseRemote(
      failures,
      () {
        // The server pages languages, so the page is read as one, and its
        // tags are flattened afterwards. `meta` stays the languages'.
        final languages = PaginatedResult.fromEnvelope(
          response.body,
          key: 'languages',
          item: _languageTags,
        );
        return PaginatedResult(
          items: [for (final tags in languages.items) ...tags],
          meta: languages.meta,
        );
      },
      action: action,
      status: response.status,
    );
  }

  static String _pathOf(String id) => '$_basePath/${Uri.encodeComponent(id)}';

  static String _languageLinksPath(String id) =>
      '${_pathOf(id)}/language-links';

  static String _languageLinkPath(String id, String linkId) =>
      '${_languageLinksPath(id)}/${Uri.encodeComponent(linkId)}';

  /// Reads `{ dataGateway, connection_* | disconnection_* }`, the body every
  /// change route answers with.
  DataGatewayChangeResult _changeResult(
    RemoteJson response, {
    required String action,
    required _GatewayFailures family,
  }) => parseRemote(
    family,
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

  /// Reads `{ dataGateway, interview_attempt, interview_response }`, the body
  /// the interview route answers with.
  ///
  /// `interview_attempt` is always true there, so it says nothing and is not
  /// read.
  DataGatewayInterviewResult _interviewResult(
    RemoteJson response, {
    required String action,
    required _GatewayFailures family,
  }) => parseRemote(
    family,
    () {
      final body = response.body;
      final answer = body['interview_response'];
      if (answer is! Map<String, dynamic>) {
        throw const FormatException(
          'response is missing an "interview_response" object',
        );
      }
      return DataGatewayInterviewResult(
        dataGateway: _mapDataGateway(_dataGatewayObject(body)),
        succeeded: answer['success'] as bool,
      );
    },
    action: action,
    status: response.status,
  );

  /// Reads `{ languageLink }`, the body every language link action answers
  /// with: the link as it stands afterwards.
  LanguageLink _languageLinkResult(
    RemoteJson response, {
    required String action,
    required _GatewayFailures family,
  }) => parseRemote(
    family,
    () {
      final row = response.body['languageLink'];
      if (row is! Map<String, dynamic>) {
        throw const FormatException(
          'response is missing a "languageLink" object',
        );
      }
      return _mapLanguageLink(row);
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
  /// holds. In particular it never touches `authParameters` (#41), and it
  /// reads `interview` rather than the raw `lastInterview*` columns that block
  /// is derived from: the server has already decided which failure is current
  /// (#457).
  ///
  /// `interview`, `sections` and both capability lists are required. A row
  /// without them is not one this client can show, so it fails to parse
  /// instead of reading as a DataGateway with nothing to say.
  static DataGateway _mapDataGateway(Map<String, dynamic> json) => DataGateway(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    connectionUrl: json['connectionUrl'] as String,
    connectionPort: json['connectionPort'] as int,
    enabled: json['enabled'] as bool,
    authType: DataGatewayAuthType.fromWire(json['authType'] as String),
    interview: _mapInterview(json['interview'] as Map<String, dynamic>),
    sections: [
      for (final section in json['sections'] as List)
        _mapSection(section as Map<String, dynamic>),
    ],
    capabilities: _names(json['capabilities']),
    disabledCapabilities: _names(json['disabledCapabilities']),
  );

  static DataGatewayInterviewStatus _mapInterview(Map<String, dynamic> json) {
    final failure = json['failure'] as Map<String, dynamic>?;
    return DataGatewayInterviewStatus(
      interviewed: json['interviewed'] as bool,
      firstInterviewedAt: _dateOrNull(json['firstInterviewedAt']),
      lastInterviewedAt: _dateOrNull(json['lastInterviewedAt']),
      failure: failure == null
          ? null
          : DataGatewayInterviewFailure(
              code: DataGatewayInterviewFailureCode.fromWire(
                failure['code'] as String,
              ),
              at: DateTime.parse(failure['at'] as String),
            ),
    );
  }

  static DataGatewaySection _mapSection(Map<String, dynamic> json) {
    final failure = json['failure'] as Map<String, dynamic>?;
    return DataGatewaySection(
      capability: json['capability'] as String,
      lastLoadedAt: _dateOrNull(json['lastLoadedAt']),
      failure: failure == null
          ? null
          : DataGatewaySectionFailure(
              code: DataGatewaySectionFailureCode.fromWire(
                failure['code'] as String,
              ),
              at: DateTime.parse(failure['at'] as String),
            ),
    );
  }

  /// Capability names, kept as the server sent them (#457). Copied here, so a
  /// name that is not a string fails the parse rather than a later read.
  static List<String> _names(Object? wire) => List<String>.from(wire! as List);

  static DateTime? _dateOrNull(Object? wire) =>
      wire == null ? null : DateTime.parse(wire as String);

  /// Maps a server row to [LanguageLink], field by field. Of the columns the
  /// server sends, it reads only the ones the model holds.
  ///
  /// A status or a format it does not know degrades to its `unknown`, so the
  /// row survives.
  static LanguageLink _mapLanguageLink(Map<String, dynamic> json) {
    final tag = json['tag'] as Map<String, dynamic>?;
    return LanguageLink(
      id: json['id'] as String,
      value: json['value'] as String,
      format: LanguageCodeFormat.fromWire(json['format'] as String?),
      status: LanguageLinkStatus.fromWire(json['status'] as String),
      tag: tag == null ? null : _mapLanguageTag(tag),
      suppliedName: json['suppliedName'] as String?,
      suppliedNativeName: json['suppliedNativeName'] as String?,
      suppliedIetfTag: json['suppliedIetfTag'] as String?,
    );
  }

  static LanguageTagRef _mapLanguageTag(Map<String, dynamic> json) =>
      LanguageTagRef(
        id: json['id'] as String,
        tag: json['tag'] as String,
        name: json['name'] as String,
      );

  /// The tags of one language row from the catalogue, in the order sent. A
  /// language may have none.
  static List<LanguageTagRef> _languageTags(Map<String, dynamic> json) => [
    for (final tag in json['tags'] as List)
      _mapLanguageTag(tag as Map<String, dynamic>),
  ];

  // ── Guards: requests the server is guaranteed to reject ─────────────

  /// [ceiling] is the route's own: the catalogue allows smaller pages than the
  /// DataGateway routes do.
  void _checkPaging({
    required int page,
    required int limit,
    required int ceiling,
  }) {
    if (limit < 1 || limit > ceiling) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $ceiling (the server rejects a larger page '
            'rather than clamping it)',
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
}

/// How the DataGateway source builds its failures for the shared classifier.
final class _GatewayFailures
    extends RemoteFailureFamily<DataGatewayRemoteException> {
  const _GatewayFailures({
    required this.rowRoute,
    this.conflictIsName = false,
    this.timeoutIsUnknown = false,
    this.browser = false,
  }) : super(
         transient: DataGatewayTransientException.new,
         permanent: DataGatewayPermanentException.new,
       );

  /// Whether the path names one DataGateway, which is what lets an
  /// application 404 mean that row is gone.
  final bool rowRoute;

  /// Whether a 409 from the API means another DataGateway has the name. Only
  /// the routes that take a name say so. Any other route's 409 is the row's
  /// state refusing the request, a [DataGatewayConflictException].
  final bool conflictIsName;

  /// Whether the server may still be working on a request that ran out of
  /// time, so the outcome is unknown. Such a request throws
  /// [DataGatewayTimedOutException], not a transient failure.
  final bool timeoutIsUnknown;

  /// Whether a browser's adapter carries the requests. See
  /// [DataGatewayRemoteDataSourceImpl.interviewTimeout].
  final bool browser;

  /// Every answer here is a conclusion about the caller's role or about a
  /// row, and only the application's own envelope licenses one, so a 403, a
  /// 404 or a 409 needs [RemoteRefusal.fromApi]. A 404 is a missing row only
  /// on a [rowRoute]: Nest answers an unregistered route with this same
  /// envelope, so on the list route even an application 404 means "not
  /// deployed", not "no rows", and takes the shared default, transient. A 409
  /// is [DataGatewayNameInUseException] on a route that takes a name
  /// ([conflictIsName]) and [DataGatewayConflictException] on the others.
  ///
  /// A 400 without the envelope is a proxy's, which says nothing about what
  /// the request asked for, so it is transient. A link's enveloped 400 is the
  /// server saying it has no such tag, and takes the shared default,
  /// permanent.
  @override
  DataGatewayRemoteException? refused(RemoteRefusal refusal) {
    final status = refusal.status;
    final message = refusal.message;
    final cause = refusal.cause;
    if (!refusal.fromApi) {
      return status == 400
          ? transient(
              '$message; the request did not reach the API',
              statusCode: status,
              cause: cause,
            )
          : null;
    }
    return switch (status) {
      403 => DataGatewayForbiddenException(
        message,
        statusCode: status,
        cause: cause,
      ),
      404 when rowRoute => DataGatewayNotFoundException(
        message,
        statusCode: status,
        cause: cause,
      ),
      409 when conflictIsName => DataGatewayNameInUseException(
        message,
        statusCode: status,
        cause: cause,
      ),
      409 => DataGatewayConflictException(
        message,
        statusCode: status,
        cause: cause,
      ),
      _ => null,
    };
  }

  /// A request that ran out of time while the server may still be working is
  /// [DataGatewayTimedOutException], when [timeoutIsUnknown] says so.
  @override
  DataGatewayRemoteException? unanswered(DioException error, String message) =>
      timeoutIsUnknown && _ranOutOfTime(error.type)
      ? DataGatewayTimedOutException(
          '$message; it timed out and the server may still be working',
          cause: error,
        )
      : null;

  /// Whether a request that failed with [type] ran out of time waiting for an
  /// answer. A browser reports a slow answer as a connection timeout (see
  /// [DataGatewayRemoteDataSourceImpl.interviewTimeout]). Elsewhere a
  /// connection timeout means the request never left, so it says nothing is
  /// running on the server.
  bool _ranOutOfTime(DioExceptionType type) =>
      type == DioExceptionType.receiveTimeout ||
      (browser && type == DioExceptionType.connectionTimeout);
}
