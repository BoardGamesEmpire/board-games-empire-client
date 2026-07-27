import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [HouseholdRemoteDataSource] over a **per-server** Dio instance (#39).
///
/// The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included), and the existing per-server auth
/// plumbing (TokenInterceptor) attaches the BetterAuth session the endpoint
/// requires. This class adds no auth handling of its own; it is constructed
/// from the per-server container by the network installer (#39 wiring), so
/// unlike [WellKnownClientImpl] it does **not** build or own its Dio, and it
/// is intentionally **not** an injectable global singleton (the per-server
/// Dio is outside the global graph).
///
/// Failure taxonomy per the [HouseholdRemoteDataSource] contract — see that
/// interface for the transient/permanent split.
class HouseholdRemoteDataSourceImpl implements HouseholdRemoteDataSource {
  const HouseholdRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  /// 4xx statuses that are nonetheless worth retrying: an expired session
  /// (401), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 408, 429};

  @override
  Future<Household> createHousehold({
    required String name,
    String? description,
    String? image,
    String? language,
    String? visibility,
  }) async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '/households',
        data: {
          'name': name,
          'description': ?description,
          'image': ?image,
          'language': ?language,
          'visibility': ?visibility,
        },
      );
    } on DioException catch (error) {
      throw _classifyDioException(error);
    } on Object catch (error) {
      // Contract breach territory (nothing else should escape Dio); stay
      // conservative and transient so the caller can retry.
      throw HouseholdRemoteTransientException(
        'Household create failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw const HouseholdRemoteTransientException(
        'Household create returned no status',
      );
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(
        status,
        'Household create returned $status',
        cause: null,
      );
    }

    final data = response.data;
    final household = data == null ? null : data['household'];
    if (household is! Map<String, dynamic>) {
      throw HouseholdRemotePermanentException(
        'Household create response missing a "household" object',
        statusCode: status,
      );
    }

    try {
      return _mapHousehold(household);
    } on Object catch (error) {
      throw HouseholdRemotePermanentException(
        'Failed to parse created household: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  /// Maps the server household payload to the domain [Household].
  ///
  /// Explicit field mapping (not [Household.fromJson]) keeps the server
  /// representation decoupled from the local-persistence representation:
  /// the server response carries fields the model doesn't (languageTagId,
  /// createdById, visibility, embedded members …) and omits the client-only
  /// sync flags, which default to `false` for this server-confirmed row.
  Household _mapHousehold(Map<String, dynamic> json) => Household(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    image: json['image'] as String?,
    deletedAt: _dateOrNull(json['deletedAt']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  static DateTime? _dateOrNull(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  /// A response status, when present, is authoritative; without one the
  /// failure is a connection-level fault and always transient.
  HouseholdRemoteException _classifyDioException(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        'Household create failed with status $status',
        cause: error,
      );
    }
    return HouseholdRemoteTransientException(
      'Household create failed',
      cause: error,
    );
  }

  HouseholdRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
  }) {
    final transient = status >= 500 || _retryable4xx.contains(status);
    if (transient) {
      return HouseholdRemoteTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status >= 400) {
      return HouseholdRemotePermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A non-2xx, non-4xx/5xx status (1xx/3xx surfaced by a permissive
    // validateStatus) carries no rejection semantics — transient.
    return HouseholdRemoteTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
