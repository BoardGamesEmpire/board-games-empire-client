import 'package:dio/dio.dart';
import 'package:dio_network/src/household/household_member_json.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [AdminHouseholdRemoteDataSource] over a **per-server** Dio instance (#685).
///
/// Built like [DataGatewayRemoteDataSourceImpl]: the body is asked for as a
/// `String`, `sendForJson` decodes it after the status is read, and a failure
/// is classified through [_AdminHouseholdFailures]. It does not build or own
/// its Dio. The roster of a household's detail is read with
/// [mapHouseholdMember], as the household source reads its own.
///
/// Failure taxonomy per the [AdminHouseholdRemoteDataSource] contract.
class AdminHouseholdRemoteDataSourceImpl
    implements AdminHouseholdRemoteDataSource {
  const AdminHouseholdRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _listPath = '/api/admin/households';
  static const String _basePath = '/api/households';

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<PaginatedResult<AdminHouseholdRow>> fetchPage({
    AdminHouseholdStatus status = AdminHouseholdStatus.live,
    String? query,
    AdminHouseholdSort sort = AdminHouseholdSort.name,
    int page = 1,
    int limit = AdminHouseholdRemoteDataSource.pageSize,
  }) async {
    if (limit < 1 || limit > AdminHouseholdRemoteDataSource.maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and ${AdminHouseholdRemoteDataSource.maxPageSize} '
            '(the server rejects a larger page rather than clamping it)',
      );
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'is 1-based');
    }
    if (!sort.allowedWith(status)) {
      throw ArgumentError.value(
        sort,
        'sort',
        'the deleted order needs deleted rows, and status is ${status.name}',
      );
    }
    final term = query?.trim();
    if (term != null) {
      final length = AdminHouseholdRemoteDataSource.queryLength(term);
      if (length < AdminHouseholdRemoteDataSource.minQueryLength ||
          length > AdminHouseholdRemoteDataSource.maxQueryLength) {
        throw ArgumentError.value(
          query,
          'query',
          'must be ${AdminHouseholdRemoteDataSource.minQueryLength} to '
              '${AdminHouseholdRemoteDataSource.maxQueryLength} characters '
              'once trimmed',
        );
      }
    }

    const action = 'Staff household list';
    // A list route is never absent for a caller who reached it, so even an
    // application 404 here means the route is not deployed.
    const failures = _AdminHouseholdFailures(rowRoute: false);
    final response = await sendForJson(
      () => _dio.get<String>(
        _listPath,
        options: _plainBody,
        queryParameters: {
          'status': status.wireName,
          'sort': sort.wireName,
          'page': page,
          'limit': limit,
          'q': ?term,
        },
      ),
      action: action,
      family: failures,
    );

    return parseRemote(
      failures,
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'households',
        item: _mapRow,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<AdminHouseholdDetail> fetchDetail(String id) async {
    const action = 'Staff household fetch';
    const failures = _AdminHouseholdFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.get<String>(_pathOf(id), options: _plainBody),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapDetail(response.body),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<void> restore(String id) async {
    const action = 'Staff household restore';
    await sendForJson(
      () => _dio.post<String>('${_pathOf(id)}/restore', options: _plainBody),
      action: action,
      family: const _AdminHouseholdFailures(rowRoute: true, restoreRoute: true),
      readBody: false,
    );
  }

  static String _pathOf(String id) => '$_basePath/${Uri.encodeComponent(id)}';

  static AdminHouseholdRow _mapRow(Map<String, dynamic> json) {
    final deletedAt = json['deletedAt'] as String?;
    return AdminHouseholdRow(
      id: json['id'] as String,
      name: json['name'] as String,
      image: json['image'] as String?,
      reach: Reach.fromWire(json['reach'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      deletedAt: deletedAt == null ? null : DateTime.parse(deletedAt),
      memberCount: json['memberCount'] as int,
      owners: [
        for (final owner in json['owners'] as List)
          _mapOwner(owner as Map<String, dynamic>),
      ],
    );
  }

  static AdminHouseholdOwner _mapOwner(Map<String, dynamic> json) =>
      AdminHouseholdOwner(
        userId: json['userId'] as String,
        username: json['username'] as String,
        displayName: json['displayName'] as String?,
      );

  /// Reads `{ household: { ..., languageTag, members } }`.
  ///
  /// `members` is required: a detail with no roster is not one to show, and
  /// reading it as an empty household would be wrong.
  static AdminHouseholdDetail _mapDetail(Map<String, dynamic> body) {
    final json = body['household'];
    if (json is! Map<String, dynamic>) {
      throw FormatException(
        json == null
            ? 'response is missing the "household" object'
            : 'response field "household" is ${json.runtimeType}, expected '
                  'an object',
      );
    }
    final members = json['members'];
    if (members is! List) {
      throw FormatException(
        members == null
            ? 'household is missing the "members" array'
            : 'household "members" is ${members.runtimeType}, expected a list',
      );
    }
    final language = json['languageTag'];
    if (language != null && language is! Map<String, dynamic>) {
      throw FormatException(
        'household "languageTag" is ${language.runtimeType}, expected an '
        'object or null',
      );
    }
    return AdminHouseholdDetail(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      image: json['image'] as String?,
      reach: Reach.fromWire(json['reach'] as String),
      languageName: (language as Map<String, dynamic>?)?['name'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      members: [
        for (final member in members)
          mapHouseholdMember(member as Map<String, dynamic>),
      ],
    );
  }
}

/// How the staff households source builds its failures for the shared
/// classifier.
final class _AdminHouseholdFailures
    extends RemoteFailureFamily<AdminHouseholdRemoteException> {
  const _AdminHouseholdFailures({
    required this.rowRoute,
    this.restoreRoute = false,
  }) : super(
         transient: AdminHouseholdTransientException.new,
         permanent: AdminHouseholdPermanentException.new,
       );

  /// Whether the path names one household, which is what lets an application
  /// 404 mean that household is gone.
  final bool rowRoute;

  /// Whether this is the restore route, whose enveloped 409 means the
  /// household is not deleted. Any other route has no 409 of its own.
  final bool restoreRoute;

  /// Every answer here is a conclusion about the caller's role or a
  /// household, and only the application's own envelope licenses one, so a
  /// 403, 404 or 409 needs [RemoteRefusal.fromApi]. A 404 is a missing
  /// household only on a [rowRoute]: Nest answers an unregistered route with
  /// the same envelope, so on the list route it means "not deployed" and takes
  /// the shared default, transient. A retryable 409 never reaches here.
  @override
  AdminHouseholdRemoteException? refused(RemoteRefusal refusal) {
    if (!refusal.fromApi) return null;
    final status = refusal.status;
    final message = refusal.message;
    final cause = refusal.cause;
    return switch (status) {
      403 => AdminHouseholdForbiddenException(
        message,
        statusCode: status,
        cause: cause,
      ),
      404 when rowRoute => AdminHouseholdNotFoundException(
        message,
        statusCode: status,
        cause: cause,
      ),
      409 when restoreRoute => AdminHouseholdNotDeletedException(
        message,
        statusCode: status,
        cause: cause,
      ),
      _ => null,
    };
  }
}
