import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A DataGateway row as the backend serializes the Prisma model at
/// `a182bf38` (backend PR #750, merged): every column, `authParameters`
/// included, because the controller returns the row unfiltered until
/// backend#753.
Map<String, dynamic> _row({
  String id = 'dg_1',
  String name = 'BoardGameGeek',
  String? description = 'The BGG bridge',
  bool enabled = true,
  String authType = 'None',
  Object? authParameters = const {'token': 's3cret-token'},
}) => {
  'id': id,
  'name': name,
  'description': description,
  'messageContext': 'JSON',
  'iconUrl': null,
  'logoUrl': null,
  'websiteUrl': 'https://boardgamegeek.com',
  'apiBaseUrl': null,
  'apiDocumentation': null,
  'apiVersion': null,
  'connectionUrl': 'bgg-gateway.internal',
  'connectionPort': 50051,
  'enabled': enabled,
  'authType': authType,
  'authParameters': authParameters,
  'usageCount': 12,
  'lastUsed': '2026-10-14T18:00:00.000Z',
  'languagesSyncedAt': null,
  'createdById': 'user_owner',
  'deletedAt': null,
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-14T18:00:00.000Z',
};

String _listBody(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int limit = 100,
  int? total,
  bool hasMore = false,
}) => jsonEncode({
  'dataGateways': rows,
  'pagination': {
    'page': page,
    'limit': limit,
    'total': total ?? rows.length,
    'totalPages': 1,
    'hasMore': hasMore,
  },
});

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status, String error, String message) =>
    jsonEncode({'statusCode': status, 'message': message, 'error': error});

/// One request as the transport received it.
typedef _Sent = ({
  String method,
  String path,
  Map<String, dynamic> query,
  Object? body,
});

/// Answers every request with one canned response, and records what it was
/// sent. [CannedAdapter] can't do the second half.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body, this.status);

  final String body;
  final int status;
  final List<_Sent> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object? requestBody;
    if (requestStream != null) {
      final bytes = await requestStream.expand((chunk) => chunk).toList();
      requestBody = jsonDecode(utf8.decode(bytes));
    }
    sent.add((
      method: options.method,
      path: options.path,
      query: options.queryParameters,
      body: requestBody,
    ));
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;

  /// A data source over a real Dio, permissive about status like the
  /// production factories.
  DataGatewayRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return DataGatewayRemoteDataSourceImpl(dio);
  }

  group('fetchPage', () {
    test('reads the rows and the paging from the list envelope', () async {
      final remote = answering(
        _listBody(
          [_row(), _row(id: 'dg_2', name: 'Steam', enabled: false)],
          total: 7,
          hasMore: true,
        ),
      );

      final page = await remote.fetchPage();

      expect(page.items, [
        DataGateway(
          id: 'dg_1',
          name: 'BoardGameGeek',
          description: 'The BGG bridge',
          connectionUrl: 'bgg-gateway.internal',
          connectionPort: 50051,
          enabled: true,
          authType: DataGatewayAuthType.none,
        ),
        DataGateway(
          id: 'dg_2',
          name: 'Steam',
          description: 'The BGG bridge',
          connectionUrl: 'bgg-gateway.internal',
          connectionPort: 50051,
          enabled: false,
          authType: DataGatewayAuthType.none,
        ),
      ]);
      expect(page.meta.total, 7);
      expect(page.meta.hasMore, isTrue);
    });

    test('asks for the page and limit it was given', () async {
      final remote = answering(_listBody([]));

      await remote.fetchPage(page: 2, limit: 1);

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/data-gateways');
      expect(adapter.sent.single.query, {'page': 2, 'limit': 1});
    });

    test('never carries the stored credentials into the row (#41)', () async {
      final remote = answering(_listBody([_row()]));

      final row = (await remote.fetchPage()).items.single;

      expect(row.toString(), isNot(contains('s3cret-token')));
    });

    test(
      'reads an auth type it does not know as unknown, not a failure',
      () async {
        final remote = answering(_listBody([_row(authType: 'Kerberos')]));

        final row = (await remote.fetchPage()).items.single;

        expect(row.authType, DataGatewayAuthType.unknown);
      },
    );
  });

  group('fetchOne', () {
    test('reads the single-row envelope', () async {
      final remote = answering(jsonEncode({'dataGateway': _row(id: 'dg_9')}));

      final row = await remote.fetchOne('dg_9');

      expect(row.id, 'dg_9');
      expect(adapter.sent.single.path, '/api/data-gateways/dg_9');
    });
  });

  group('create', () {
    const input = DataGatewayInput(
      name: 'BoardGameGeek',
      connectionUrl: 'bgg-gateway.internal',
      connectionPort: 50051,
      description: 'The BGG bridge',
    );

    String created({bool success = true}) => jsonEncode({
      'dataGateway': _row(),
      'connection_response': success
          ? {'success': true}
          : {'success': false, 'message': 'Could not connect.'},
      'connection_attempt': true,
    });

    test('sends the "None" auth type and no credentials (#41)', () async {
      final remote = answering(created(), status: 201);

      await remote.create(input);

      final sent = adapter.sent.single;
      expect(sent.method, 'POST');
      expect(sent.path, '/api/data-gateways');
      expect(sent.body, {
        'name': 'BoardGameGeek',
        'connectionUrl': 'bgg-gateway.internal',
        'connectionPort': 50051,
        'authType': 'None',
        'description': 'The BGG bridge',
      });
    });

    test('leaves a blank description out rather than sending null', () async {
      final remote = answering(created(), status: 201);

      await remote.create(
        const DataGatewayInput(
          name: 'Steam',
          connectionUrl: 'steam-gateway.internal',
          connectionPort: 50052,
        ),
      );

      expect(
        (adapter.sent.single.body! as Map).containsKey('description'),
        isFalse,
      );
    });

    test('reports the connect the server tried', () async {
      final remote = answering(created(), status: 201);

      final result = await remote.create(input);

      expect(result.dataGateway.id, 'dg_1');
      expect(
        result.connectionAttempt,
        const DataGatewayConnectionAttempt(
          action: DataGatewayConnectionAction.connect,
          succeeded: true,
        ),
      );
    });

    test('reports a failed connect as an attempt, not an exception: the '
        'server answers it with a 2xx', () async {
      final remote = answering(created(success: false), status: 201);

      final result = await remote.create(input);

      expect(result.connectionAttempt?.succeeded, isFalse);
    });

    test('reports no attempt when the server made none', () async {
      final remote = answering(
        jsonEncode({
          'dataGateway': _row(enabled: false),
          'connection_response': null,
          'connection_attempt': false,
        }),
        status: 201,
      );

      final result = await remote.create(input);

      expect(result.connectionAttempt, isNull);
    });

    test('a 409 from the API is a name already in use', () async {
      final remote = answering(
        _envelope(409, 'Conflict', 'A DataGateway with that name exists.'),
        status: 409,
      );

      await expectLater(
        remote.create(input),
        throwsA(isA<DataGatewayNameInUseException>()),
      );
    });

    test('a duplicate name answers 500 until backend#754, which reads as '
        'transient, not as the name being in use', () async {
      final remote = answering(
        _envelope(500, 'Internal Server Error', 'Internal server error'),
        status: 500,
      );

      await expectLater(
        remote.create(input),
        throwsA(isA<DataGatewayTransientException>()),
      );
    });

    test('a 400 from the API is permanent', () async {
      final remote = answering(
        _envelope(400, 'Bad Request', 'connectionPort is too large'),
        status: 400,
      );

      await expectLater(
        remote.create(input),
        throwsA(isA<DataGatewayPermanentException>()),
      );
    });
  });

  group('update', () {
    String updated() => jsonEncode({
      'dataGateway': _row(),
      'connection_response': null,
      'connection_attempt': false,
    });

    test('sends only the fields that changed', () async {
      final remote = answering(updated());

      await remote.update(
        'dg_1',
        const DataGatewayChanges(connectionPort: 50060),
      );

      final sent = adapter.sent.single;
      expect(sent.method, 'PATCH');
      expect(sent.path, '/api/data-gateways/dg_1');
      expect(sent.body, {'connectionPort': 50060});
    });

    test('an emptied description is sent as null, which clears it', () async {
      final remote = answering(updated());

      await remote.update('dg_1', const DataGatewayChanges(description: ''));

      expect(adapter.sent.single.body, {'description': null});
    });

    test('refuses an empty change before sending anything; the server '
        'answers one with a 400', () {
      final remote = answering(updated());

      expect(
        () => remote.update('dg_1', const DataGatewayChanges()),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test(
      'reports no connection attempt; the server reconnects on its own',
      () async {
        final remote = answering(updated());

        final result = await remote.update(
          'dg_1',
          const DataGatewayChanges(name: 'BGG'),
        );

        expect(result.connectionAttempt, isNull);
      },
    );

    test('a 404 from the API means the row is gone', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'DataGateway dg_1 was not found.'),
        status: 404,
      );

      await expectLater(
        remote.update('dg_1', const DataGatewayChanges(name: 'BGG')),
        throwsA(isA<DataGatewayNotFoundException>()),
      );
    });
  });

  group('delete, connect and disconnect', () {
    test('delete reports the disconnect the server tried', () async {
      final remote = answering(
        jsonEncode({
          'dataGateway': _row(),
          'disconnection_response': {'success': true},
          'disconnection_attempt': true,
        }),
      );

      final result = await remote.delete('dg_1');

      expect(adapter.sent.single.method, 'DELETE');
      expect(adapter.sent.single.path, '/api/data-gateways/dg_1');
      expect(
        result.connectionAttempt,
        const DataGatewayConnectionAttempt(
          action: DataGatewayConnectionAction.disconnect,
          succeeded: true,
        ),
      );
    });

    test("connect posts to the row's connect route", () async {
      final remote = answering(
        jsonEncode({
          'dataGateway': _row(),
          'connection_response': {'success': false, 'message': 'No.'},
          'connection_attempt': true,
        }),
        status: 201,
      );

      final result = await remote.connect('dg_1');

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/data-gateways/dg_1/connect');
      expect(
        result.connectionAttempt,
        const DataGatewayConnectionAttempt(
          action: DataGatewayConnectionAction.connect,
          succeeded: false,
        ),
      );
    });

    test("disconnect posts to the row's disconnect route", () async {
      final remote = answering(
        jsonEncode({
          'dataGateway': _row(enabled: false),
          'disconnection_response': {'success': true},
          'disconnection_attempt': true,
        }),
        status: 201,
      );

      final result = await remote.disconnect('dg_1');

      expect(adapter.sent.single.path, '/api/data-gateways/dg_1/disconnect');
      expect(result.dataGateway.enabled, isFalse);
      expect(
        result.connectionAttempt?.action,
        DataGatewayConnectionAction.disconnect,
      );
    });
  });

  group('who may call it (#41)', () {
    test("a 403 from the API is a refusal of the caller's role", () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'You are not allowed to do that.'),
        status: 403,
      );

      await expectLater(
        remote.fetchPage(limit: 1),
        throwsA(isA<DataGatewayForbiddenException>()),
      );
    });

    test('a 403 without the envelope came from a proxy, so it is transient '
        'and says nothing about the role', () async {
      final remote = answering(
        '<html>Blocked by corporate proxy</html>',
        status: 403,
      );

      await expectLater(
        remote.connect('dg_1'),
        throwsA(isA<DataGatewayTransientException>()),
      );
    });

    test('a 404 on the list route is transient even from the API: the route '
        'is not deployed, as on a server older than the rename', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'Cannot GET /api/data-gateways'),
        status: 404,
      );

      await expectLater(
        remote.fetchPage(limit: 1),
        throwsA(isA<DataGatewayTransientException>()),
      );
    });

    test('an HTML 200 is permanent, with its status', () async {
      final remote = answering('<html>Sign in to the hotel wifi</html>');

      await expectLater(
        remote.fetchPage(),
        throwsA(
          isA<DataGatewayPermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            200,
          ),
        ),
      );
    });

    test('an unreachable server is transient', () async {
      final remote = DataGatewayRemoteDataSourceImpl(
        unreachableDio(DioExceptionType.connectionError),
      );

      await expectLater(
        remote.fetchPage(limit: 1),
        throwsA(isA<DataGatewayTransientException>()),
      );
    });
  });
}
