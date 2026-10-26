import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

// Every body below is shaped from the backend source, not recorded from a
// running server. At a21cd51e, `GameService.getGames` returns bare Prisma
// rows, `getGame` adds the includes listed there, and the search service's
// `queryLocalGames` / `mapProtoGame` build each result. At 83e62bb0, the
// import controller answers the start, and `GameImportStatusService`'s
// `toBatchDto` / `toJobDto` build the poll's. A game row's columns are the
// `Game` model's at cb287e07: a `reach`, and play time in minutes with no
// unit (#602).

/// A catalog row: every scalar column of the Prisma `Game` model, which
/// `findMany` returns with no `select`.
Map<String, dynamic> _gameRow({
  String id = 'g_catan',
  String title = 'Catan',
  Object? complexity = 2.3,
  String image = 'https://cf.geekdo-images.com/catan.jpg',
  String thumbnail = 'https://cf.geekdo-images.com/catan_t.jpg',
  String contentType = 'BaseGame',
  Object? reach = 'Public',
}) => {
  'id': id,
  'title': title,
  'subtitle': 'Trade, build, settle',
  'description': 'Settle **Catan**.\n\n- Trade\n- Build',
  'image': image,
  'thumbnail': thumbnail,
  'publishYear': 1995,
  'minPlayers': 3,
  'maxPlayers': 4,
  'minPlayTime': 60,
  'maxPlayTime': 120,
  'minAge': 10,
  'complexity': complexity,
  'totalPlayCount': 12,
  'averageRating': 7.1,
  'bayesRating': 6.9,
  'ratingsCount': 120000,
  'ownedByCount': 3,
  'enrichmentSource': 'bgg',
  'frozenAt': null,
  'contentType': contentType,
  'reach': ?reach,
  'createdById': 'user_service',
  'updatedById': null,
  'deletedAt': null,
  'createdAt': '2026-09-01T10:00:00.000Z',
  'updatedAt': '2026-10-01T12:30:00.000Z',
};

/// What `GET /games/:id` adds to the row: the includes in
/// `GameService.getGame`, and no platform games.
Map<String, dynamic> _detailRow({Object? platformGames}) => {
  ..._gameRow(),
  'artists': [
    {
      'id': 'ga_1',
      'role': null,
      'details': null,
      'artist': {'id': 'a_1', 'name': 'Michael Menzel'},
    },
  ],
  'categories': [
    {
      'id': 'gc_1',
      'isPrimary': true,
      'category': {'id': 'c_1', 'name': 'Negotiation'},
    },
  ],
  'designers': [
    {
      'id': 'gd_1',
      'role': null,
      'designer': {'id': 'd_1', 'name': 'Klaus Teuber'},
    },
  ],
  'families': <Object>[],
  'mechanics': [
    {
      'id': 'gm_1',
      'mechanic': {
        'id': 'm_1',
        'name': 'Dice Rolling',
        'description': null,
        'complexity': null,
      },
    },
  ],
  'publishers': <Object>[],
  'tags': <Object>[],
  'expansions': <Object>[],
  'platformGames': ?platformGames,
};

/// The Game [_gameRow] maps to.
final _catan = Game(
  id: 'g_catan',
  title: 'Catan',
  subtitle: 'Trade, build, settle',
  description: 'Settle **Catan**.\n\n- Trade\n- Build',
  image: 'https://cf.geekdo-images.com/catan.jpg',
  thumbnail: 'https://cf.geekdo-images.com/catan_t.jpg',
  publishYear: 1995,
  minPlayers: 3,
  maxPlayers: 4,
  minPlayTime: 60,
  maxPlayTime: 120,
  minAge: 10,
  complexity: 2.3,
  totalPlayCount: 12,
  averageRating: 7.1,
  bayesRating: 6.9,
  ratingsCount: 120000,
  ownedByCount: 3,
  reach: Reach.public,
  createdById: 'user_service',
  createdAt: DateTime.utc(2026, 9, 1, 10),
  updatedAt: DateTime.utc(2026, 10, 1, 12, 30),
);

String _catalogBody(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int limit = 100,
  bool hasMore = false,
}) => jsonEncode({
  'games': rows,
  'pagination': {
    'page': page,
    'limit': limit,
    'total': rows.length,
    'totalPages': 1,
    'hasMore': hasMore,
  },
});

/// A local search result, as `queryLocalGames` maps a row: the Platform's id
/// in `platforms[].externalId`, stored enum names, `inSystem: true`.
Map<String, dynamic> _localHit({String id = 'g_catan'}) => {
  'externalId': id,
  'title': 'Catan',
  'contentType': 'BaseGame',
  'yearPublished': 1995,
  'thumbnailUrl': 'https://cf.geekdo-images.com/catan_t.jpg',
  'sourceUrl': 'https://boardgamegeek.com/boardgame/13',
  'averageRating': 7.1,
  'minPlayers': 3,
  'maxPlayers': 4,
  'inSystem': true,
  'gameId': id,
  'platforms': [
    {
      'externalId': 'plat_tabletop',
      'name': 'Tabletop',
      'platformType': 'Tabletop',
    },
  ],
  'availableReleases': <Object>[],
};

/// A DataGateway result, as `mapProtoGame` maps a coordinator frame: proto
/// enum names, and `gameId` only when the server holds the game.
Map<String, dynamic> _gatewayHit({
  String externalId = '13',
  String title = 'Catan',
  bool inSystem = false,
  String? gameId,
  String contentType = 'CONTENT_TYPE_EXPANSION',
  String thumbnailUrl = '',
}) => {
  'externalId': externalId,
  'title': title,
  'contentType': contentType,
  'yearPublished': 1996,
  'thumbnailUrl': thumbnailUrl,
  'sourceUrl': 'https://boardgamegeek.com/boardgame/$externalId',
  'minPlayers': 2,
  'maxPlayers': 6,
  'baseGameExternalId': '13',
  'inSystem': inSystem,
  'gameId': ?gameId,
  'platforms': [
    {
      'externalId': 'bgg-tabletop',
      'name': 'Board game',
      'abbreviation': 'BG',
      'platformType': 'PLATFORM_TYPE_TABLETOP',
    },
  ],
  'availableReleases': <Object>[],
};

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status, String error) => jsonEncode({
  'statusCode': status,
  'message': 'Something about it.',
  'error': error,
});

/// The import batch every import body names: the server mints a v4 UUID.
const _batch = '0b7c2f9e-3a41-4c8e-9d2a-5f6b7c8d9e0f';

/// The correlation id an import is started with.
const _corr = '5a1e4b3c-2d6f-4a8b-9c0d-1e2f3a4b5c6d';

/// What `POST /games/import` answers once the import is queued.
String _receiptBody() => jsonEncode({
  'message': 'Import queued',
  'batchId': _batch,
  'baseJobId': 'job_base',
  'expansionJobIds': <String>[],
  'correlationId': _corr,
});

/// One job of a polled batch, as `toJobDto` maps a `Job` row: the result's
/// fields only once the job has one, and `undefined` left out.
Map<String, dynamic> _jobRow({
  String status = 'Running',
  String? gameId,
  String? gameTitle,
  Object? platformGames,
  String? errorCode,
  bool isExpansion = false,
}) => {
  'jobId': isExpansion ? 'job_expansion' : 'job_base',
  'status': status,
  'isExpansion': isExpansion,
  'parentJobId': isExpansion ? 'job_base' : null,
  // The coordinator snapshots the requested expansions on the base job only.
  if (!isExpansion) 'requestedExpansions': <String>[],
  'externalId': isExpansion ? '927' : '926',
  'gameId': ?gameId,
  'gameTitle': ?gameTitle,
  // A completed job's result stores its thumbnail, null or not.
  if (gameId != null) 'thumbnail': null,
  'platformGames': ?platformGames,
  'errorCode': ?errorCode,
  if (errorCode != null) 'error': 'Fetching game data from the gateway failed.',
  'startedAt': status == 'Pending' ? null : '2026-10-26T10:00:00.000Z',
  'completedAt': const {'Pending', 'Running'}.contains(status)
      ? null
      : '2026-10-26T10:00:04.000Z',
};

/// What `GET /games/import/:batchId` answers.
String _batchBody({
  String status = 'Running',
  List<Map<String, dynamic>>? jobs,
}) => jsonEncode({
  'batchId': _batch,
  'correlationId': _corr,
  'status': status,
  'jobs': jobs ?? [_jobRow()],
});

/// One request as the transport received it.
typedef _Sent = ({
  String method,
  String path,
  Map<String, dynamic> query,
  Duration? receiveTimeout,
  Object? data,
});

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
      receiveTimeout: options.receiveTimeout,
      data: options.data,
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
  /// production factories' ten-second receive timeout.
  GamesRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(
      BaseOptions(
        validateStatus: (_) => true,
        receiveTimeout: const Duration(seconds: 10),
      ),
    )..httpClientAdapter = adapter;
    return GamesRemoteDataSourceImpl(dio);
  }

  group('fetchPage', () {
    test('reads a catalog row and the paging', () async {
      final remote = answering(_catalogBody([_gameRow()], hasMore: true));

      final page = await remote.fetchPage();

      expect(page.items, [_catan]);
      expect(page.meta.hasMore, isTrue);
    });

    test('asks for the page and limit it was given', () async {
      final remote = answering(_catalogBody([]));

      await remote.fetchPage(page: 3, limit: 50);

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/games');
      expect(adapter.sent.single.query, {'page': 3, 'limit': 50});
    });

    test('reads a float column the server sent as a whole number', () async {
      final remote = answering(_catalogBody([_gameRow(complexity: 3)]));

      final game = (await remote.fetchPage()).items.single;

      expect(game.complexity, 3.0);
    });

    test('reads an empty image or thumbnail as none', () async {
      // The server's own search treats an empty thumbnail as none
      // (`game.thumbnail || undefined`), so the column can hold one.
      final remote = answering(
        _catalogBody([_gameRow(image: '', thumbnail: '')]),
      );

      final game = (await remote.fetchPage()).items.single;

      expect((game.image, game.thumbnail), (null, null));
    });

    test('degrades names it does not know rather than failing the page', () {
      final remote = answering(
        _catalogBody([_gameRow(contentType: 'Miniature', reach: 'Guild')]),
      );

      return expectLater(
        remote.fetchPage().then((page) => page.items.single),
        completion(
          isA<Game>()
              .having((g) => g.contentType, 'type', ContentType.unknown)
              .having((g) => g.reach, 'reach', Reach.unknown),
        ),
      );
    });

    test('reads a row with no reach as unknown', () {
      final remote = answering(_catalogBody([_gameRow(reach: null)]));
      return expectLater(
        remote.fetchPage().then((page) => page.items.single.reach),
        completion(Reach.unknown),
      );
    });

    test('refuses a page the server would reject, before sending it', () {
      final remote = answering(_catalogBody([]));

      expect(() => remote.fetchPage(page: 0), throwsArgumentError);
      expect(() => remote.fetchPage(limit: 0), throwsArgumentError);
      expect(() => remote.fetchPage(limit: 101), throwsArgumentError);
      expect(
        () => remote.fetchPage(page: 1002, limit: 100),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('a 404 from the list route is transient, envelope or not', () {
      final remote = answering(_envelope(404, 'Not Found'), status: 404);

      expect(remote.fetchPage(), throwsA(isA<GamesRemoteTransientException>()));
    });

    test('a body that is not the catalog envelope is permanent', () {
      final remote = answering(jsonEncode({'rows': <Object>[]}));

      expect(remote.fetchPage(), throwsA(isA<GamesRemotePermanentException>()));
    });
  });

  group('fetchGame', () {
    test('reads the game and drops the nested relations', () async {
      final remote = answering(jsonEncode({'game': _detailRow()}));

      final read = await remote.fetchGame('g_catan');

      expect(read.game, _catan);
      expect(adapter.sent.single.path, '/api/games/g_catan');
    });

    test('has no platform games while the server sends none '
        '(backend#791)', () async {
      final remote = answering(jsonEncode({'game': _detailRow()}));

      final read = await remote.fetchGame('g_catan');

      expect(read.platformGames, isEmpty);
    });

    test('reads the platform games once the server sends them', () async {
      final remote = answering(
        jsonEncode({
          'game': _detailRow(
            platformGames: [
              {
                'id': 'pg_1',
                'platform': {
                  'id': 'plat_tabletop',
                  'name': 'Tabletop',
                  'abbreviation': null,
                  'platformType': 'Tabletop',
                },
              },
            ],
          ),
        }),
      );

      final read = await remote.fetchGame('g_catan');

      expect(read.platformGames, [
        const PlatformGameSummary(
          id: 'pg_1',
          platformId: 'plat_tabletop',
          platformName: 'Tabletop',
          game: GameSummary(
            id: 'g_catan',
            title: 'Catan',
            subtitle: 'Trade, build, settle',
            image: 'https://cf.geekdo-images.com/catan.jpg',
            thumbnail: 'https://cf.geekdo-images.com/catan_t.jpg',
          ),
        ),
      ]);
    });

    test('skips a platform game it cannot read, and still reads the game '
        '(backend#791 has not settled the shape)', () async {
      final remote = answering(
        jsonEncode({
          'game': _detailRow(
            platformGames: [
              {'id': 'pg_1', 'platformId': 'plat_tabletop'},
              {
                'id': 'pg_2',
                'platform': {'id': 'plat_steam', 'name': 'Steam'},
              },
            ],
          ),
        }),
      );

      final read = await remote.fetchGame('g_catan');

      expect(read.game, _catan);
      expect(read.platformGames.map((pg) => pg.id), ['pg_2']);
    });

    test('an application 404 is a missing game', () {
      final remote = answering(_envelope(404, 'Not Found'), status: 404);

      expect(remote.fetchGame('g_gone'), throwsA(isA<GameNotFoundException>()));
    });

    test('an application 403 is a game the caller may not read', () {
      final remote = answering(_envelope(403, 'Forbidden'), status: 403);

      expect(
        remote.fetchGame('g_private'),
        throwsA(isA<GamesForbiddenException>()),
      );
    });

    test('a 404 without the envelope came from a proxy, so it is '
        'transient', () {
      final remote = answering('<html>Not Found</html>', status: 404);

      expect(
        remote.fetchGame('g_catan'),
        throwsA(isA<GamesRemoteTransientException>()),
      );
    });

    test('refuses an id that is not one path segment', () {
      final remote = answering(jsonEncode({'game': _detailRow()}));

      expect(() => remote.fetchGame(''), throwsArgumentError);
      expect(() => remote.fetchGame('a/b'), throwsArgumentError);
      expect(() => remote.fetchGame('x' * 129), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });
  });

  group('search', () {
    String searchBody() => jsonEncode({
      'correlationId': 'c-1',
      'resultsBySource': {
        'local': [_localHit()],
        'dg_bgg': [
          _gatewayHit(inSystem: true, gameId: 'g_catan'),
          _gatewayHit(externalId: '926', title: 'Catan: Seafarers'),
        ],
      },
      'errors': {
        'dg_igdb': {'message': 'Unknown error'},
      },
      'rateLimitedSources': ['dg_steam'],
      'unavailableSources': ['dg_down'],
    });

    test('reads a local result, named the stored way', () async {
      final remote = answering(searchBody());

      final results = await remote.search('catan');

      expect(results.local, [
        const GameSearchHit(
          externalId: 'g_catan',
          title: 'Catan',
          contentType: ContentType.baseGame,
          gameId: 'g_catan',
          yearPublished: 1995,
          minPlayers: 3,
          maxPlayers: 4,
          thumbnailUrl: 'https://cf.geekdo-images.com/catan_t.jpg',
          platforms: [
            GameSearchPlatform(
              name: 'Tabletop',
              platformType: PlatformType.tabletop,
            ),
          ],
        ),
      ]);
    });

    test('reads a DataGateway result, named the proto way', () async {
      final remote = answering(searchBody());

      final hits = (await remote.search('catan')).byDataGateway['dg_bgg']!;

      expect(
        hits[1],
        const GameSearchHit(
          externalId: '926',
          title: 'Catan: Seafarers',
          contentType: ContentType.expansion,
          yearPublished: 1996,
          minPlayers: 2,
          maxPlayers: 6,
          platforms: [
            GameSearchPlatform(
              name: 'Board game',
              abbreviation: 'BG',
              platformType: PlatformType.tabletop,
            ),
          ],
        ),
      );
    });

    test(
      'keeps the game id of a DataGateway result the server holds',
      () async {
        final remote = answering(searchBody());

        final hits = (await remote.search('catan')).byDataGateway['dg_bgg']!;

        expect(hits[0].gameId, 'g_catan');
        expect(hits[1].isOnServer, isFalse);
      },
    );

    test('names every source that did not answer, by how', () async {
      final remote = answering(searchBody());

      final results = await remote.search('catan');

      expect(results.failedDataGateways, {'dg_igdb'});
      expect(results.rateLimitedDataGateways, {'dg_steam'});
      expect(results.unavailableDataGateways, {'dg_down'});
    });

    test('reads a search with no local results and nothing missing', () async {
      final remote = answering(
        jsonEncode({'correlationId': 'c-2', 'resultsBySource': {}}),
      );

      final results = await remote.search('zzz');

      expect(results, const GameSearchResults());
    });

    test('sends the query, the page and both filters by their stored '
        'names', () async {
      final remote = answering(searchBody());

      await remote.search(
        'catan',
        limit: 10,
        offset: 20,
        contentTypes: {ContentType.baseGame, ContentType.standaloneExpansion},
        platformTypes: {PlatformType.tabletop, PlatformType.pc},
      );

      final sent = adapter.sent.single;
      expect(sent.path, '/api/games/search');
      expect(sent.query, {
        'query': 'catan',
        'limit': 10,
        'offset': 20,
        'contentTypes': 'BaseGame,StandaloneExpansion',
        'platformTypes': 'Tabletop,PC',
      });
    });

    test('leaves an empty filter out', () async {
      final remote = answering(searchBody());

      await remote.search('catan');

      expect(adapter.sent.single.query, {
        'query': 'catan',
        'limit': GamesRemoteDataSource.searchPageSize,
        'offset': 0,
      });
    });

    test('waits longer than the server\'s 15-second cutoff', () async {
      final remote = answering(searchBody());

      await remote.search('catan');

      expect(
        adapter.sent.single.receiveTimeout,
        greaterThan(const Duration(seconds: 15)),
      );
    });

    test('refuses a filter naming an unknown type, and a page out of '
        'range', () {
      final remote = answering(searchBody());

      expect(
        () => remote.search('x', contentTypes: {ContentType.unknown}),
        throwsArgumentError,
      );
      expect(
        () => remote.search('x', platformTypes: {PlatformType.unknown}),
        throwsArgumentError,
      );
      expect(() => remote.search('x', limit: 0), throwsArgumentError);
      expect(() => remote.search('x', offset: -1), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('a 404 from the search route is transient, envelope or not', () {
      final remote = answering(_envelope(404, 'Not Found'), status: 404);

      expect(
        remote.search('catan'),
        throwsA(isA<GamesRemoteTransientException>()),
      );
    });
  });

  group('import', () {
    Future<GameImportReceipt> start(GamesRemoteDataSource remote) =>
        remote.startImport(
          gatewayId: 'dg_bgg',
          externalId: '926',
          correlationId: _corr,
        );

    test('startImport sends the three fields and reads the receipt', () async {
      final remote = answering(_receiptBody(), status: 201);

      final receipt = await start(remote);

      final sent = adapter.sent.single;
      expect(sent.method, 'POST');
      expect(sent.path, '/api/games/import');
      expect(sent.data, {
        'gatewayId': 'dg_bgg',
        'externalId': '926',
        'correlationId': _corr,
      });
      expect(
        receipt,
        const GameImportReceipt(
          batchId: _batch,
          baseJobId: 'job_base',
          correlationId: _corr,
        ),
      );
    });

    test('startImport refuses a correlation id that is not a UUID, before '
        'sending', () {
      final remote = answering(_receiptBody(), status: 201);

      expect(
        () => remote.startImport(
          gatewayId: 'dg_bgg',
          externalId: '926',
          correlationId: 'ck1abc',
        ),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('startImport refuses an empty gateway or external id, before '
        'sending', () {
      final remote = answering(_receiptBody(), status: 201);

      expect(
        () => remote.startImport(
          gatewayId: '',
          externalId: '926',
          correlationId: _corr,
        ),
        throwsArgumentError,
      );
      expect(
        () => remote.startImport(
          gatewayId: 'dg_bgg',
          externalId: '',
          correlationId: _corr,
        ),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('fetchImport reads a completed base job and its platform '
        'games', () async {
      final remote = answering(
        _batchBody(
          status: 'Completed',
          jobs: [
            _jobRow(
              status: 'Completed',
              gameId: 'g_seafarers',
              gameTitle: 'Catan: Seafarers',
              platformGames: [
                {'platformId': 'plat_tabletop', 'platformGameId': 'pg_1'},
              ],
            ),
          ],
        ),
      );

      final batch = await remote.fetchImport(_batch);

      expect(adapter.sent.single.path, '/api/games/import/$_batch');
      expect(
        batch,
        const ImportBatch(
          batchId: _batch,
          correlationId: _corr,
          status: ImportBatchStatus.completed,
          jobs: [
            ImportJob(
              jobId: 'job_base',
              status: ImportJobStatus.completed,
              isExpansion: false,
              externalId: '926',
              gameId: 'g_seafarers',
              gameTitle: 'Catan: Seafarers',
              platformGames: [
                ImportPlatformGame(
                  platformId: 'plat_tabletop',
                  platformGameId: 'pg_1',
                ),
              ],
            ),
          ],
        ),
      );
    });

    test("fetchImport tells the base game's job from an expansion's", () async {
      final remote = answering(
        _batchBody(
          jobs: [
            _jobRow(),
            _jobRow(status: 'Pending', isExpansion: true),
          ],
        ),
      );

      final batch = await remote.fetchImport(_batch);

      expect(batch.jobs.map((job) => (job.jobId, job.isExpansion)), [
        ('job_base', false),
        ('job_expansion', true),
      ]);
    });

    test("fetchImport reads a failed job's error code", () async {
      final remote = answering(
        _batchBody(
          status: 'Failed',
          jobs: [_jobRow(status: 'Failed', errorCode: 'GATEWAY_ERROR')],
        ),
      );

      final job = (await remote.fetchImport(_batch)).jobs.single;

      expect(job.status, ImportJobStatus.failed);
      expect(job.errorCode, ImportErrorCode.gatewayError);
    });

    test('fetchImport reads names it does not know as unknown', () async {
      final remote = answering(
        _batchBody(
          status: 'Paused',
          jobs: [_jobRow(status: 'Paused', errorCode: 'TIMEOUT')],
        ),
      );

      final batch = await remote.fetchImport(_batch);

      expect(batch.status, ImportBatchStatus.unknown);
      expect(batch.jobs.single.status, ImportJobStatus.unknown);
      expect(batch.jobs.single.errorCode, ImportErrorCode.unknown);
    });

    test('an application 404 on the poll is an unknown import', () {
      final remote = answering(_envelope(404, 'Not Found'), status: 404);

      expect(
        remote.fetchImport(_batch),
        throwsA(isA<GameImportNotFoundException>()),
      );
    });

    test('a 404 on the poll without the envelope came from a proxy, so it is '
        'transient', () {
      final remote = answering('<html>Not Found</html>', status: 404);

      expect(
        remote.fetchImport(_batch),
        throwsA(isA<GamesRemoteTransientException>()),
      );
    });

    test('an application 403 on either route is forbidden', () async {
      final remote = answering(_envelope(403, 'Forbidden'), status: 403);

      await expectLater(start(remote), throwsA(isA<GamesForbiddenException>()));
      await expectLater(
        remote.fetchImport(_batch),
        throwsA(isA<GamesForbiddenException>()),
      );
    });

    test('a 404 on the start route is transient, envelope or not', () async {
      for (final body in [
        _envelope(404, 'Not Found'),
        '<html>Not Found</html>',
      ]) {
        await expectLater(
          start(answering(body, status: 404)),
          throwsA(isA<GamesRemoteTransientException>()),
          reason: body,
        );
      }
    });

    test('fetchImport refuses a batch id that is not a UUID, before '
        'sending', () {
      final remote = answering(_batchBody());

      expect(() => remote.fetchImport('../games'), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('a poll body without jobs is permanent', () {
      final remote = answering(
        jsonEncode({
          'batchId': _batch,
          'correlationId': _corr,
          'status': 'Running',
        }),
      );

      expect(
        remote.fetchImport(_batch),
        throwsA(isA<GamesRemotePermanentException>()),
      );
    });
  });
}
