import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

// Every body below is shaped from the backend source at c8f42b83:
// `HouseholdGamePoolService.sampleGamePool` answers `{ games, gameCount }`,
// each game the `GAME_SUMMARY_SELECT` columns (#960), and the e2e spec
// pins `{ games: [], gameCount: 0 }` for a caller with no household.

/// A game summary as the sample sends it.
Map<String, dynamic> _summaryRow({
  String id = 'g_catan',
  String title = 'Catan',
  Object? thumbnail = 'https://cf.geekdo-images.com/catan_t.jpg',
}) => {
  'id': id,
  'title': title,
  'thumbnail': thumbnail,
  'description': 'Settle **Catan**.',
};

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status, String error) => jsonEncode({
  'statusCode': status,
  'message': 'Something about it.',
  'error': error,
});

typedef _Sent = ({String method, String path, Map<String, dynamic> query});

/// Answers every request with one canned response, and records what it was
/// sent.
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
    sent.add((
      method: options.method,
      path: options.path,
      query: options.queryParameters,
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

  /// A data source over a real Dio, permissive about status as the
  /// production factory's is.
  HouseholdRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return HouseholdRemoteDataSourceImpl(dio);
  }

  group('fetchGamePoolSample', () {
    test('reads GET /api/households/game-pool/random?size=1', () async {
      final remote = answering(
        jsonEncode({
          'games': [_summaryRow()],
          'gameCount': 7,
        }),
      );

      final sample = await remote.fetchGamePoolSample(size: 1);

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/households/game-pool/random');
      expect(adapter.sent.single.query, {'size': 1});
      expect(sample.gameCount, 7);
      expect(sample.games, const [
        GameSummary(
          id: 'g_catan',
          title: 'Catan',
          thumbnail: 'https://cf.geekdo-images.com/catan_t.jpg',
        ),
      ]);
    });

    test('asks for the default sample size', () async {
      final remote = answering(jsonEncode({'games': [], 'gameCount': 0}));

      await remote.fetchGamePoolSample();

      expect(adapter.sent.single.query, {
        'size': GamesRemoteDataSource.defaultSampleSize,
      });
    });

    test('reads an empty thumbnail or a missing one as none', () async {
      final remote = answering(
        jsonEncode({
          'games': [
            _summaryRow(id: 'g_azul', title: 'Azul', thumbnail: ''),
            _summaryRow(id: 'g_brass', title: 'Brass', thumbnail: null),
          ],
          'gameCount': 2,
        }),
      );

      final sample = await remote.fetchGamePoolSample();

      expect(sample.games.map((g) => g.thumbnail), [null, null]);
    });

    test('no household answer is no games and a count of 0', () async {
      // The server answers 200 with this for a caller in no household, so it
      // is a sample like any other.
      final remote = answering(jsonEncode({'games': [], 'gameCount': 0}));

      final sample = await remote.fetchGamePoolSample();

      expect(sample.games, isEmpty);
      expect(sample.gameCount, 0);
    });

    test('a body with no gameCount is permanent', () {
      final remote = answering(
        jsonEncode({
          'games': [_summaryRow()],
        }),
      );

      expect(
        remote.fetchGamePoolSample(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a gameCount that is not a whole number is permanent', () {
      final remote = answering(
        jsonEncode({'games': <Object>[], 'gameCount': '7'}),
      );

      expect(
        remote.fetchGamePoolSample(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a body with no games array is permanent', () {
      final remote = answering(jsonEncode({'gameCount': 0}));

      expect(
        remote.fetchGamePoolSample(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('refuses size 0 and 51, before sending it', () {
      final remote = answering(jsonEncode({'games': [], 'gameCount': 0}));

      expect(() => remote.fetchGamePoolSample(size: 0), throwsArgumentError);
      expect(() => remote.fetchGamePoolSample(size: 51), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('an application 403 is permanent', () {
      final remote = answering(_envelope(403, 'Forbidden'), status: 403);

      expect(
        remote.fetchGamePoolSample(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a 404 is transient, envelope or not: the route is fixed', () {
      final remote = answering(_envelope(404, 'Not Found'), status: 404);

      expect(
        remote.fetchGamePoolSample(),
        throwsA(isA<HouseholdRemoteTransientException>()),
      );
    });

    test('a 500 is transient', () {
      final remote = answering(_envelope(500, 'Server'), status: 500);

      expect(
        remote.fetchGamePoolSample(),
        throwsA(isA<HouseholdRemoteTransientException>()),
      );
    });
  });
}
