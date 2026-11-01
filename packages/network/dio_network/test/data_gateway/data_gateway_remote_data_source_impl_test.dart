import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A DataGateway row as the backend serializes it at `5f4f0728`: every column
/// but the stored credentials, which no route returns since backend#753 (the
/// row says only whether there are any), and with the `interview` block and
/// `sections` the server derives.
///
/// The raw interview columns are not derived from the `interview` a test
/// passes. The client reads the block, so a test that passes its own fails if
/// the mapping reads the columns instead.
Map<String, dynamic> _row({
  String id = 'dg_1',
  String name = 'BoardGameGeek',
  String? description = 'The BGG bridge',
  bool enabled = true,
  String authType = 'None',
  List<String> capabilities = _allCapabilities,
  List<String> disabledCapabilities = const [],
  Map<String, dynamic>? interview,
  List<Map<String, dynamic>>? sections,
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
  'hasAuthParameters': false,
  'usageCount': 12,
  'lastUsed': '2026-10-14T18:00:00.000Z',
  'capabilities': capabilities,
  'coveragePlatformTypes': ['Tabletop'],
  'coverageContentTypes': ['BaseGame', 'Expansion'],
  'filterableAxes': ['ContentType', 'PublishYear'],
  'acceptedLanguageCodeFormats': ['Iso6391'],
  'responseLanguageCodeFormat': 'Iso6391',
  'passthroughSearchLanguage': false,
  'contentFormat': 'Html',
  'gatewayVersion': '1.4.2',
  'disabledCapabilities': disabledCapabilities,
  'firstInterviewedAt': '2026-10-01T10:35:00.000Z',
  'lastInterviewedAt': '2026-10-14T18:00:00.000Z',
  'lastInterviewFailedAt': null,
  'lastInterviewFailure': null,
  'interview': interview ?? _interview(),
  'sections': sections ?? _loadedSections(),
  'createdById': 'user_owner',
  'deletedAt': null,
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-14T18:00:00.000Z',
};

/// What a DataGateway that serves everything this client knows of declares,
/// spelled as the server spells it. Written out rather than read from
/// `DataGatewayCapabilities`, so a mistyped constant fails a test.
const _allCapabilities = [
  'Search',
  'Fetch',
  'FetchExpansions',
  'ListLanguages',
  'ListPlatforms',
  'ListCategories',
  'ListMechanics',
];

/// The `interview` block of a DataGateway whose last interview succeeded.
Map<String, dynamic> _interview({
  bool interviewed = true,
  String? firstInterviewedAt = '2026-10-01T10:35:00.000Z',
  String? lastInterviewedAt = '2026-10-14T18:00:00.000Z',
  Map<String, dynamic>? failure,
}) => {
  'interviewed': interviewed,
  'firstInterviewedAt': firstInterviewedAt,
  'lastInterviewedAt': lastInterviewedAt,
  'failure': failure,
};

/// One entry of `sections`: a list job that has not loaded, unless given a
/// time.
Map<String, dynamic> _section(
  String capability, {
  String? lastLoadedAt,
  Map<String, dynamic>? failure,
}) => {
  'capability': capability,
  'lastLoadedAt': lastLoadedAt,
  'failure': failure,
};

/// The four list jobs, run a minute apart and in the server's order, all
/// loaded.
List<Map<String, dynamic>> _loadedSections() => [
  _section('ListLanguages', lastLoadedAt: '2026-10-14T18:01:00.000Z'),
  _section('ListPlatforms', lastLoadedAt: '2026-10-14T18:02:00.000Z'),
  _section('ListCategories', lastLoadedAt: '2026-10-14T18:03:00.000Z'),
  _section('ListMechanics', lastLoadedAt: '2026-10-14T18:04:00.000Z'),
];

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

/// The backend's rendering of a deadlock that outlived its own retry.
String _retryableConflict() => jsonEncode({
  'statusCode': 409,
  'error': 'Conflict',
  'message': 'The request collided with another; try it again.',
  'code': 'TransactionDeadlockError',
  'retryable': true,
});

/// What the production factories give every request, before a source asks for
/// more.
const _factoryTimeout = Duration(seconds: 10);

/// One request as the transport received it.
typedef _Sent = ({
  String method,
  String path,
  Map<String, dynamic> query,
  Object? body,
  Duration? connectTimeout,
  Duration? receiveTimeout,
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
      connectTimeout: options.connectTimeout,
      receiveTimeout: options.receiveTimeout,
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

  /// A data source over a real Dio, permissive about status and holding the
  /// timeouts of the production factories.
  DataGatewayRemoteDataSource answering(
    String body, {
    int status = 200,
    bool browser = false,
  }) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(
      BaseOptions(
        validateStatus: (_) => true,
        connectTimeout: _factoryTimeout,
        receiveTimeout: _factoryTimeout,
      ),
    )..httpClientAdapter = adapter;
    return DataGatewayRemoteDataSourceImpl(dio, browser: browser);
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

      // What `_row` sends by default, as the model holds it.
      final interview = DataGatewayInterviewStatus(
        interviewed: true,
        firstInterviewedAt: DateTime.utc(2026, 10, 1, 10, 35),
        lastInterviewedAt: DateTime.utc(2026, 10, 14, 18),
      );
      final sections = [
        DataGatewaySection(
          capability: 'ListLanguages',
          lastLoadedAt: DateTime.utc(2026, 10, 14, 18, 1),
        ),
        DataGatewaySection(
          capability: 'ListPlatforms',
          lastLoadedAt: DateTime.utc(2026, 10, 14, 18, 2),
        ),
        DataGatewaySection(
          capability: 'ListCategories',
          lastLoadedAt: DateTime.utc(2026, 10, 14, 18, 3),
        ),
        DataGatewaySection(
          capability: 'ListMechanics',
          lastLoadedAt: DateTime.utc(2026, 10, 14, 18, 4),
        ),
      ];

      expect(page.items, [
        DataGateway(
          id: 'dg_1',
          name: 'BoardGameGeek',
          description: 'The BGG bridge',
          connectionUrl: 'bgg-gateway.internal',
          connectionPort: 50051,
          enabled: true,
          authType: DataGatewayAuthType.none,
          interview: interview,
          sections: sections,
          capabilities: DataGatewayCapabilities.known,
        ),
        DataGateway(
          id: 'dg_2',
          name: 'Steam',
          description: 'The BGG bridge',
          connectionUrl: 'bgg-gateway.internal',
          connectionPort: 50051,
          enabled: false,
          authType: DataGatewayAuthType.none,
          interview: interview,
          sections: sections,
          capabilities: DataGatewayCapabilities.known,
        ),
      ]);
      expect(
        page.items.first.sections.map((s) => s.capability),
        DataGatewayCapabilities.lists,
      );
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

    test('never carries stray credentials into the row, even from a server '
        'that still sends them (#41)', () async {
      final remote = answering(
        _listBody([
          _row()..['authParameters'] = {'token': 's3cret-token'},
        ]),
      );

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

  group("reading a row's interview, sections and capabilities (#457)", () {
    Future<DataGateway> read(Map<String, dynamic> row) async =>
        (await answering(_listBody([row])).fetchPage()).items.single;

    test('reads the interview block, with a current failure', () async {
      final row = await read(
        _row(
          interview: _interview(
            failure: {'code': 'PingFailed', 'at': '2026-10-29T10:00:00.000Z'},
          ),
        ),
      );

      expect(
        row.interview,
        DataGatewayInterviewStatus(
          interviewed: true,
          firstInterviewedAt: DateTime.utc(2026, 10, 1, 10, 35),
          lastInterviewedAt: DateTime.utc(2026, 10, 14, 18),
          failure: DataGatewayInterviewFailure(
            code: DataGatewayInterviewFailureCode.pingFailed,
            at: DateTime.utc(2026, 10, 29, 10),
          ),
        ),
      );
    });

    test('reads a never-interviewed row', () async {
      final row = await read(
        _row(
          interview: _interview(
            interviewed: false,
            firstInterviewedAt: null,
            lastInterviewedAt: null,
          ),
        ),
      );

      expect(row.interview.interviewed, isFalse);
      expect(row.interview.firstInterviewedAt, isNull);
      expect(row.interview.lastInterviewedAt, isNull);
      expect(row.interview.failure, isNull);
    });

    test('reads the interview block, not the raw columns it is derived from: a '
        'failure the server no longer calls current stays out', () async {
      // A later success leaves the failure columns in place. The block
      // already says the failure is over, and the client does not compare
      // the two times itself.
      final raw = _row()
        ..['lastInterviewFailedAt'] = '2026-10-10T09:00:00.000Z'
        ..['lastInterviewFailure'] = 'PingFailed';

      final row = await read(raw);

      expect(row.interview.failure, isNull);
    });

    test('reads sections, a failed one and one that never loaded', () async {
      final row = await read(
        _row(
          sections: [
            _section('ListLanguages', lastLoadedAt: '2026-10-14T18:01:00.000Z'),
            _section(
              'ListPlatforms',
              lastLoadedAt: '2026-10-14T18:02:00.000Z',
              failure: {'code': 'ListFailed', 'at': '2026-10-21T18:02:00.000Z'},
            ),
            _section('ListCategories'),
          ],
        ),
      );

      expect(row.sections, [
        DataGatewaySection(
          capability: 'ListLanguages',
          lastLoadedAt: DateTime.utc(2026, 10, 14, 18, 1),
        ),
        DataGatewaySection(
          capability: 'ListPlatforms',
          lastLoadedAt: DateTime.utc(2026, 10, 14, 18, 2),
          failure: DataGatewaySectionFailure(
            code: DataGatewaySectionFailureCode.listFailed,
            at: DateTime.utc(2026, 10, 21, 18, 2),
          ),
        ),
        const DataGatewaySection(capability: 'ListCategories'),
      ]);
    });

    test('keeps capability names it does not know, as sent', () async {
      final row = await read(
        _row(
          capabilities: ['Search', 'FutureThing'],
          disabledCapabilities: ['Search', 'FutureThing'],
          sections: [_section('FutureThing')],
        ),
      );

      expect(row.capabilities, ['Search', 'FutureThing']);
      expect(row.disabledCapabilities, ['Search', 'FutureThing']);
      expect(row.sections.single.capability, 'FutureThing');
    });

    test('reads every interview failure code the server defines', () async {
      const codes = {
        'PingFailed': DataGatewayInterviewFailureCode.pingFailed,
        'DescribeUnsupported':
            DataGatewayInterviewFailureCode.describeUnsupported,
        'DescribeFailed': DataGatewayInterviewFailureCode.describeFailed,
      };

      for (final MapEntry(key: wire, value: code) in codes.entries) {
        final row = await read(
          _row(
            interview: _interview(
              failure: {'code': wire, 'at': '2026-10-29T10:00:00.000Z'},
            ),
          ),
        );

        expect(row.interview.failure?.code, code, reason: '"$wire"');
      }
    });

    test('reads every section failure code the server defines', () async {
      const codes = {
        'ListUnsupported': DataGatewaySectionFailureCode.listUnsupported,
        'ListFailed': DataGatewaySectionFailureCode.listFailed,
        'LinkFailed': DataGatewaySectionFailureCode.linkFailed,
      };

      for (final MapEntry(key: wire, value: code) in codes.entries) {
        final row = await read(
          _row(
            sections: [
              _section(
                'ListLanguages',
                failure: {'code': wire, 'at': '2026-10-29T10:00:00.000Z'},
              ),
            ],
          ),
        );

        expect(row.sections.single.failure?.code, code, reason: '"$wire"');
      }
    });

    test('an interview code it does not know degrades, and the row '
        'survives', () async {
      final row = await read(
        _row(
          interview: _interview(
            failure: {'code': 'NewCode', 'at': '2026-10-29T10:00:00.000Z'},
          ),
        ),
      );

      expect(row.id, 'dg_1');
      expect(
        row.interview.failure?.code,
        DataGatewayInterviewFailureCode.unknown,
      );
      expect(row.interview.failure?.at, DateTime.utc(2026, 10, 29, 10));
    });

    test('a section code it does not know degrades, and the row '
        'survives', () async {
      final row = await read(
        _row(
          sections: [
            _section(
              'ListLanguages',
              failure: {'code': 'NewCode', 'at': '2026-10-29T10:00:00.000Z'},
            ),
          ],
        ),
      );

      expect(row.id, 'dg_1');
      expect(
        row.sections.single.failure?.code,
        DataGatewaySectionFailureCode.unknown,
      );
      expect(row.sections.single.failure?.at, DateTime.utc(2026, 10, 29, 10));
    });

    test('a row with no interview block is a permanent failure', () async {
      final remote = answering(_listBody([_row()..remove('interview')]));

      await expectLater(
        remote.fetchPage(),
        throwsA(isA<DataGatewayPermanentException>()),
      );
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

    test('a 409 from the API is still a name already in use: an edit can '
        'rename', () async {
      final remote = answering(
        _envelope(409, 'Conflict', 'A DataGateway with that name exists.'),
        status: 409,
      );

      await expectLater(
        remote.update('dg_1', const DataGatewayChanges(name: 'Steam')),
        throwsA(isA<DataGatewayNameInUseException>()),
      );
    });

    test('a 409 for a deadlock is transient, not the name being in use: '
        'nothing about the edit was wrong', () async {
      final remote = answering(_retryableConflict(), status: 409);

      await expectLater(
        remote.update('dg_1', const DataGatewayChanges(connectionPort: 8443)),
        throwsA(isA<DataGatewayTransientException>()),
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

  group('capability writes (#457)', () {
    /// What a PATCH that leaves `enabled` alone answers: the row, and no
    /// connection attempt.
    String switched({List<String> disabled = const []}) => jsonEncode({
      'dataGateway': _row(disabledCapabilities: disabled),
      'connection_response': null,
      'connection_attempt': false,
    });

    test(
      'setDisabledCapabilities sends the whole list, in the order given',
      () async {
        final remote = answering(switched(disabled: ['Search', 'FutureThing']));

        await remote.setDisabledCapabilities('dg_1', ['Search', 'FutureThing']);

        final sent = adapter.sent.single;
        expect(sent.method, 'PATCH');
        expect(sent.path, '/api/data-gateways/dg_1');
        expect(sent.body, {
          'disabledCapabilities': ['Search', 'FutureThing'],
        });
      },
    );

    test('setDisabledCapabilities sends an empty list, which switches all '
        'back on', () async {
      final remote = answering(switched());

      await remote.setDisabledCapabilities('dg_1', const []);

      expect(adapter.sent.single.body, {'disabledCapabilities': <String>[]});
    });

    test('setDisabledCapabilities reports no connection attempt', () async {
      final remote = answering(switched());

      final result = await remote.setDisabledCapabilities('dg_1', ['Search']);

      expect(result.connectionAttempt, isNull);
    });

    test('a 409 from setDisabledCapabilities is a conflict, not a name in '
        'use: the request names no name', () async {
      final remote = answering(
        _envelope(409, 'Conflict', 'The DataGateway cannot change now.'),
        status: 409,
      );

      await expectLater(
        remote.setDisabledCapabilities('dg_1', ['Search']),
        throwsA(isA<DataGatewayConflictException>()),
      );
    });
  });

  group('interview (#457)', () {
    /// The interview route's answer: the row read again, and how the interview
    /// went. The route answers 200 whatever the outcome.
    String interviewed({
      Map<String, dynamic>? response,
      Map<String, dynamic>? row,
    }) => jsonEncode({
      'dataGateway': row ?? _row(),
      'interview_attempt': true,
      'interview_response': response ?? {'success': true},
    });

    DataGatewayRemoteDataSource unreachableWith(
      DioExceptionType type, {
      bool browser = false,
    }) => DataGatewayRemoteDataSourceImpl(
      unreachableDio(type),
      browser: browser,
    );

    test('interview posts and reads a success', () async {
      final remote = answering(interviewed());

      final result = await remote.interview('dg_1');

      final sent = adapter.sent.single;
      expect(sent.method, 'POST');
      expect(sent.path, '/api/data-gateways/dg_1/interview');
      expect(sent.body, isNull);
      expect(result.dataGateway.id, 'dg_1');
      expect(result.succeeded, isTrue);
    });

    test('interview reads a failed attempt as a result, not an exception: '
        'the server answers it with a 200', () async {
      final remote = answering(
        interviewed(
          response: {
            'success': false,
            'message': 'The DataGateway could not be interviewed.',
          },
          row: _row(
            interview: _interview(
              failure: {'code': 'PingFailed', 'at': '2026-10-29T10:00:00.000Z'},
            ),
          ),
        ),
      );

      final result = await remote.interview('dg_1');

      expect(result.succeeded, isFalse);
      // The row is read again after the interview, so it already records the
      // failure.
      expect(
        result.dataGateway.interview.failure?.code,
        DataGatewayInterviewFailureCode.pingFailed,
      );
    });

    test('an interview answer with no interview_response is a permanent '
        'failure', () async {
      final remote = answering(jsonEncode({'dataGateway': _row()}));

      await expectLater(
        remote.interview('dg_1'),
        throwsA(isA<DataGatewayPermanentException>()),
      );
    });

    test('interview waits longer for its answer, and no longer to connect, so '
        'a server that cannot be reached says so at once', () async {
      final remote = answering(interviewed());

      await remote.interview('dg_1');

      final sent = adapter.sent.single;
      const interviewTimeout = DataGatewayRemoteDataSourceImpl.interviewTimeout;
      expect(sent.connectTimeout, _factoryTimeout);
      expect(sent.receiveTimeout, interviewTimeout);
      expect(interviewTimeout, greaterThan(_factoryTimeout));
    });

    test('in a browser, interview waits longer to connect as well, because a '
        'slow answer there runs on the connect timer', () async {
      final remote = answering(interviewed(), browser: true);

      await remote.interview('dg_1');

      final sent = adapter.sent.single;
      const interviewTimeout = DataGatewayRemoteDataSourceImpl.interviewTimeout;
      expect(sent.connectTimeout, interviewTimeout);
      expect(sent.receiveTimeout, interviewTimeout);
    });

    test('a timeout on any other route stays transient: only an interview is '
        'known to keep running on the server', () async {
      final remote = unreachableWith(DioExceptionType.receiveTimeout);

      await expectLater(
        remote.connect('dg_1'),
        throwsA(isA<DataGatewayTransientException>()),
      );
    });

    test('a 409 from interview is a conflict, not a name in use', () async {
      final remote = answering(
        _envelope(409, 'Conflict', 'The DataGateway dg_1 is disabled.'),
        status: 409,
      );

      await expectLater(
        remote.interview('dg_1'),
        throwsA(
          isA<DataGatewayConflictException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });

    test('a retryable 409 from interview stays transient', () async {
      final remote = answering(_retryableConflict(), status: 409);

      await expectLater(
        remote.interview('dg_1'),
        throwsA(isA<DataGatewayTransientException>()),
      );
    });

    test('a 404 from interview means the row is gone', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'DataGateway dg_1 was not found.'),
        status: 404,
      );

      await expectLater(
        remote.interview('dg_1'),
        throwsA(isA<DataGatewayNotFoundException>()),
      );
    });

    test('a receive timeout on interview is timed out, not transient: the '
        'server may still be working', () async {
      final remote = unreachableWith(DioExceptionType.receiveTimeout);

      await expectLater(
        remote.interview('dg_1'),
        throwsA(isA<DataGatewayTimedOutException>()),
      );
    });

    test('a connection timeout on interview stays transient outside a browser: '
        'the request never left', () async {
      final remote = unreachableWith(DioExceptionType.connectionTimeout);

      await expectLater(
        remote.interview('dg_1'),
        throwsA(isA<DataGatewayTransientException>()),
      );
    });

    test('a connection timeout on interview is timed out in a browser, which '
        'reports a slow answer that way', () async {
      final remote = unreachableWith(
        DioExceptionType.connectionTimeout,
        browser: true,
      );

      await expectLater(
        remote.interview('dg_1'),
        throwsA(isA<DataGatewayTimedOutException>()),
      );
    });

    test('a connection error on interview stays transient', () async {
      final remote = unreachableWith(DioExceptionType.connectionError);

      await expectLater(
        remote.interview('dg_1'),
        throwsA(isA<DataGatewayTransientException>()),
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
