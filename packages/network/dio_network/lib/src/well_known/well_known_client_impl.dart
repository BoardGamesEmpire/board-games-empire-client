import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:http_status/http_status.dart';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Dio-based implementation of [WellKnownClient].
///
/// Uses a dedicated [Dio] instance with no auth interceptors — the
/// /.well-known/bge-identity endpoint is intentionally unauthenticated and
/// must remain so. Never share this instance with authenticated API clients.
@LazySingleton(as: WellKnownClient)
class WellKnownClientImpl implements WellKnownClient {
  WellKnownClientImpl() : _dio = _buildDio();

  /// Testing constructor. Inject a pre-configured [Dio] (e.g. with a mock
  /// adapter) instead of the production instance.
  @visibleForTesting
  WellKnownClientImpl.withDio(Dio dio) : _dio = dio;

  final Dio _dio;

  static Dio _buildDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: const {'Accept': 'application/json'},
      // Never follow redirects silently — URL changes require user confirmation
      followRedirects: false,
      validateStatus: (_) => true, // We handle status ourselves
    ),
  );

  @override
  Future<ServerIdentity> fetchIdentity(String serverUrl) async {
    final url = _buildWellKnownUrl(serverUrl);

    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(url);
    } on DioException catch (e) {
      throw WellKnownUnreachableException(
        serverUrl: serverUrl,
        message: _dioErrorMessage(e),
        cause: e,
      );
    }

    if (response.statusCode == HttpStatusCode.notFound) {
      throw WellKnownNotFoundException(
        serverUrl: serverUrl,
        message:
            'No BGE identity document found at $url. '
            'Verify the server URL or confirm this is a BGE instance.',
      );
    }

    if (response.statusCode != HttpStatusCode.ok) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Unexpected HTTP ${response.statusCode} from $url',
        statusCode: response.statusCode,
      );
    }

    final data = response.data;
    if (data == null) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Empty response body from $url',
        statusCode: 200,
      );
    }

    try {
      return ServerIdentity.fromJson(data);
    } on FormatException catch (e) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Failed to parse BGE identity document: ${e.message}',
        statusCode: HttpStatusCode.ok,
        cause: e,
      );
    } catch (e) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Unexpected error parsing BGE identity document: $e',
        statusCode: 200,
        cause: e,
      );
    }
  }

  /// Builds the absolute well-known URL, normalizing trailing slashes.
  String _buildWellKnownUrl(String serverUrl) {
    final base = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return '$base/.well-known/bge-identity';
  }

  String _dioErrorMessage(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout =>
      'Connection timed out. Check the server URL and network.',
    DioExceptionType.receiveTimeout => 'Server took too long to respond.',
    DioExceptionType.connectionError =>
      'Unable to reach server. Check the URL and your connection.',
    _ => e.message ?? 'Network error: ${e.type}',
  };
}
