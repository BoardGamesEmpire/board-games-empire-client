import 'dart:async';

import 'package:dio_network/src/games/game_search_channel_impl.dart';
import 'package:dio_network/src/games/game_search_wire.dart';
import 'package:dio_network/src/games/games_remote_data_source_impl.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

// Every frame below is shaped from the backend source at a691328f, not
// recorded from a running server: `search.gateway.ts` sends the search's
// frames, `search-outbound.dto.ts` types them, and `WsErrorFilter` sends a
// refused frame's envelope on `exception`, or on `auth:error` for a 401
// (`ws-error.filter.ts`, `ws-error-payload.ts`).

const _id = '5a1e4b3c-2d6f-4a8b-9c0d-1e2f3a4b5c6d';
const _otherId = '0b7c2f9e-3a41-4c8e-9d2a-5f6b7c8d9e0f';

/// A local result, as `queryLocalGames` maps a row: stored enum names, and
/// `inSystem: true` with the game's id.
Map<String, dynamic> _localGame({String id = 'g_catan'}) => {
  'externalId': id,
  'title': 'Catan',
  'contentType': 'BaseGame',
  'yearPublished': 1995,
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
  'baseGameExternalIds': <Object>[],
};

/// A DataGateway result, as `mapProtoGame` maps a coordinator frame: proto
/// enum names, and an unset string sent as `""`.
Map<String, dynamic> _gatewayGame({
  String externalId = '926',
  String title = 'Catan: Seafarers',
  String? summary,
}) => {
  'externalId': externalId,
  'title': title,
  'contentType': 'CONTENT_TYPE_EXPANSION',
  'yearPublished': 1997,
  'thumbnailUrl': '',
  'summary': ?summary,
  'minPlayers': 3,
  'maxPlayers': 4,
  'inSystem': false,
  'platforms': [
    {
      'externalId': 'bgg-tabletop',
      'name': 'Board game',
      'abbreviation': 'BG',
      'platformType': 'PLATFORM_TYPE_TABLETOP',
    },
  ],
  'availableReleases': <Object>[],
  'baseGameExternalIds': ['13'],
};

/// The envelope `WsErrorFilter` sends for a refused `search:start`.
Map<String, Object?> _refusal(
  int status,
  String error,
  Object message, {
  String correlationId = _id,
}) => {
  'statusCode': status,
  'error': error,
  'message': message,
  'pattern': 'search:start',
  'correlationId': correlationId,
};

/// A [RealtimeLease] whose frames the test scripts. It records what the
/// channel sends, and drops a frame sent while it isn't connected, as the
/// real lease does.
final class _FakeLease implements RealtimeLease {
  _FakeLease({this.connected = true, Future<void> Function()? ready})
    : _ready = ready ?? Future<void>.value;

  final Future<void> Function() _ready;
  final StreamController<RealtimeFrame> _frames =
      StreamController<RealtimeFrame>.broadcast();

  @override
  String get namespace => '/games/search';

  @override
  bool connected;

  /// Every frame sent while connected, in order.
  final List<RealtimeFrame> sent = [];

  /// Every frame sent while not connected, which the real lease drops.
  final List<RealtimeFrame> dropped = [];

  /// How many times [ready] ran.
  int readies = 0;

  /// How many times [release] ran.
  int releases = 0;

  /// Whether any search is listening to the lease's frames.
  bool get listened => _frames.hasListener;

  /// The `search:cancel` frames sent, by their payload.
  List<Object?> get cancels => [
    for (final frame in sent)
      if (frame.event == 'search:cancel') frame.data,
  ];

  @override
  Future<void> ready({Duration timeout = RealtimeConnection.connectTimeout}) {
    readies += 1;
    return _ready();
  }

  @override
  Stream<RealtimeFrame> get frames => _frames.stream;

  @override
  void emit(String event, Object? data) =>
      (connected ? sent : dropped).add((event: event, data: data));

  @override
  Future<void> release() async {
    releases += 1;
    connected = false;
    await _frames.close();
  }

  /// The server sent [event] with [data] on the namespace.
  void hear(String event, Object? data) =>
      _frames.add((event: event, data: data));

  /// The connection dropped, as the real lease reports it.
  void drop() {
    connected = false;
    hear(RealtimeLease.disconnectEvent, 'transport close');
  }

  /// The session's connection closed under the lease.
  Future<void> end() {
    connected = false;
    return _frames.close();
  }
}

/// What a search's stream delivered: its answers, its errors, and whether it
/// ended.
final class _Heard {
  _Heard(Stream<GameSearchProgress> stream) {
    _subscription = stream.listen(
      answers.add,
      onError: errors.add,
      onDone: () => done = true,
    );
  }

  final List<GameSearchProgress> answers = [];
  final List<Object> errors = [];
  bool done = false;
  late final StreamSubscription<GameSearchProgress> _subscription;

  /// Cancels the subscription, as a caller leaving the search does.
  Future<void> cancel() => _subscription.cancel();
}

/// Answers [ids] in turn, one per search.
String Function() _idsInTurn(List<String> ids) {
  final queue = [...ids];
  return () => queue.removeAt(0);
}

/// The answer a search has given once it holds [results].
GameSearchProgress _answer(
  GameSearchResults results, {
  bool localDone = false,
  bool done = false,
  bool cutShort = false,
}) => GameSearchProgress(
  results: results,
  localDone: localDone,
  done: done,
  cutShort: cutShort,
);

/// #473: a game search over the `games/search` socket, as a stream of
/// answers so far, against a lease whose frames each test scripts.
void main() {
  late _FakeLease lease;
  late GameSearchChannelImpl channel;

  setUp(() {
    lease = _FakeLease();
    channel = GameSearchChannelImpl(lease, newCorrelationId: () => _id);
  });

  tearDown(() => channel.close());

  /// The server sent [event] for this search, with [fields] beside its id.
  void hear(String event, [Map<String, Object?> fields = const {}]) =>
      lease.hear(event, {'correlationId': _id, ...fields});

  /// This search's `search:result` from [source].
  void heardResult(String source, List<Map<String, dynamic>> games) =>
      hear('search:result', {'source': source, 'games': games});

  /// A channel over [over], closed when the test ends.
  GameSearchChannelImpl channelOver(
    RealtimeLease over, {
    String Function()? ids,
    void Function()? onSessionRejected,
  }) {
    final made = GameSearchChannelImpl(
      over,
      newCorrelationId: ids ?? () => _id,
      onSessionRejected: onSessionRejected,
    );
    addTearDown(made.close);
    return made;
  }

  group('starting', () {
    test(
      'search:start carries the correlation id, the fields and the filter as '
      'arrays',
      () {
        final stream = channel.search(
          'catan',
          limit: 10,
          offset: 20,
          filter: const GameSearchFilter(
            contentTypes: {ContentType.baseGame, ContentType.expansion},
            platformTypes: {PlatformType.tabletop},
            playerCount: GameSearchRange(min: 2, max: 4),
          ),
          includeExternal: false,
        );

        expect(lease.sent, isEmpty, reason: 'nothing is sent until listened');

        stream.listen(null);

        expect(lease.sent.single.event, 'search:start');
        expect(lease.sent.single.data, {
          'correlationId': _id,
          'query': 'catan',
          'limit': 10,
          'offset': 20,
          'includeLocal': true,
          'includeExternal': false,
          'contentTypes': ['BaseGame', 'Expansion'],
          'platformTypes': ['Tabletop'],
          'playerCountMin': 2,
          'playerCountMax': 4,
        });
        expect(lease.readies, 0, reason: 'a connected lease is not waited on');
      },
    );

    test('a search asks for the first page, from every source', () {
      channel.search('catan').listen(null);

      expect(lease.sent.single.data, {
        'correlationId': _id,
        'query': 'catan',
        'limit': GamesRemoteDataSource.searchPageSize,
        'offset': 0,
        'includeLocal': true,
        'includeExternal': true,
      });
    });

    test(
      'a correlation id is minted per search, as a UUID by default',
      () async {
        final minted = GameSearchChannelImpl(lease);
        addTearDown(minted.close);

        minted.search('catan').listen(null);
        minted.search('azul').listen(null);

        final [first, second] = [
          for (final frame in lease.sent)
            (frame.data! as Map<String, Object?>)['correlationId']! as String,
        ];
        final uuid = RegExp(
          '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
          r'[0-9a-f]{12}$',
        );
        expect(first, matches(uuid));
        expect(second, matches(uuid));
        expect(first, isNot(second));
      },
    );

    test('refuses arguments the server would, before anything is sent', () {
      expect(() => channel.search('catan', limit: 0), throwsArgumentError);
      expect(() => channel.search('catan', offset: -1), throwsArgumentError);
      expect(
        () => channel.search(
          'catan',
          filter: const GameSearchFilter(contentTypes: {ContentType.unknown}),
        ),
        throwsArgumentError,
      );
      expect(lease.sent, isEmpty);
    });

    test(
      'a disconnected lease waits for ready, and an unavailable one errors '
      'before any answer',
      () async {
        // Made here, not in setUp: a Completer held across a test's pumps.
        final connects = Completer<void>();
        final connecting = _FakeLease(
          connected: false,
          ready: () => connects.future,
        );
        final waiting = _Heard(channelOver(connecting).search('catan'));
        await pumpEventQueue();

        expect(connecting.readies, 1);
        expect(connecting.sent, isEmpty, reason: 'it waits for the connect');
        expect(connecting.dropped, isEmpty);

        connecting.connected = true;
        connects.complete();
        await pumpEventQueue();

        expect(connecting.sent.single.event, 'search:start');
        expect(waiting.errors, isEmpty);

        const refused = RealtimeUnavailableException(
          'The server refused the /games/search namespace',
          statusCode: 403,
        );
        final down = _FakeLease(
          connected: false,
          ready: () => Future<void>.error(refused),
        );
        final failed = _Heard(channelOver(down).search('catan'));
        await pumpEventQueue();

        expect(failed.answers, isEmpty);
        expect(failed.errors, [same(refused)]);
        expect(failed.done, isTrue);
        expect(down.sent, isEmpty);
        expect(down.dropped, isEmpty);
        expect(down.listened, isFalse);
      },
    );

    test(
      'a namespace that drops before the search starts is unavailable',
      () async {
        // Connected when the wait answered, and gone by the time it is heard.
        final flaky = _FakeLease(connected: false);
        final heard = _Heard(channelOver(flaky).search('catan'));
        await pumpEventQueue();

        expect(heard.errors.single, isA<RealtimeUnavailableException>());
        expect(heard.done, isTrue);
        expect(flaky.sent, isEmpty);
        expect(flaky.dropped, isEmpty);
        expect(flaky.listened, isFalse);
      },
    );

    test('any other failure to connect is unavailable too', () async {
      final broken = StateError('socket.io is in a bad way');
      final down = _FakeLease(
        connected: false,
        ready: () => Future<void>.error(broken),
      );
      final heard = _Heard(channelOver(down).search('catan'));
      await pumpEventQueue();

      expect(
        heard.errors.single,
        isA<RealtimeUnavailableException>().having(
          (e) => e.cause,
          'cause',
          same(broken),
        ),
      );
      expect(heard.done, isTrue);
    });

    test('a search cancelled while it waits sends nothing', () async {
      final connects = Completer<void>();
      final connecting = _FakeLease(
        connected: false,
        ready: () => connects.future,
      );
      final heard = _Heard(channelOver(connecting).search('catan'));
      await pumpEventQueue();

      await heard.cancel();
      connecting.connected = true;
      connects.complete();
      await pumpEventQueue();

      expect(connecting.sent, isEmpty);
      expect(connecting.listened, isFalse);
    });
  });

  group('answers', () {
    test(
      "results accumulate per source, and local's source_done sets localDone",
      () async {
        final heard = _Heard(channel.search('catan'));

        heardResult('local', [_localGame()]);
        heardResult('dg_bgg', [_gatewayGame()]);
        heardResult('dg_igdb', [_gatewayGame(externalId: '7', title: 'Catan')]);
        heardResult('dg_bgg', [
          _gatewayGame(externalId: '927', title: 'Catan: Cities & Knights'),
        ]);
        // A DataGateway finishing changes no answer.
        hear('search:source_done', {'source': 'dg_bgg'});
        hear('search:source_done', {'source': 'local'});
        await pumpEventQueue();

        final local = [mapSearchHit(_localGame())];
        final seafarers = mapSearchHit(_gatewayGame());
        final igdb = mapSearchHit(
          _gatewayGame(externalId: '7', title: 'Catan'),
        );
        final cities = mapSearchHit(
          _gatewayGame(externalId: '927', title: 'Catan: Cities & Knights'),
        );
        expect(heard.answers, [
          _answer(GameSearchResults(local: local)),
          _answer(
            GameSearchResults(
              local: local,
              byDataGateway: {
                'dg_bgg': [seafarers],
              },
            ),
          ),
          _answer(
            GameSearchResults(
              local: local,
              byDataGateway: {
                'dg_bgg': [seafarers],
                'dg_igdb': [igdb],
              },
            ),
          ),
          _answer(
            GameSearchResults(
              local: local,
              byDataGateway: {
                'dg_bgg': [seafarers, cities],
                'dg_igdb': [igdb],
              },
            ),
          ),
          _answer(
            GameSearchResults(
              local: local,
              byDataGateway: {
                'dg_bgg': [seafarers, cities],
                'dg_igdb': [igdb],
              },
            ),
            localDone: true,
          ),
        ]);
        expect(
          heard.answers.last.results.byDataGateway.keys,
          ['dg_bgg', 'dg_igdb'],
          reason: 'DataGateways keep the order their first results came in',
        );
        expect(heard.done, isFalse);
      },
    );

    test('a result with no games changes no answer', () async {
      final heard = _Heard(channel.search('zzz'));

      heardResult('local', const []);
      hear('search:source_done', {'source': 'local'});
      await pumpEventQueue();

      expect(heard.answers, [
        _answer(const GameSearchResults(), localDone: true),
      ]);
    });

    test('frames for another correlation id are ignored', () async {
      final heard = _Heard(channel.search('catan'));

      lease
        ..hear('search:result', {
          'correlationId': _otherId,
          'source': 'local',
          'games': [_localGame()],
        })
        ..hear('search:source_done', {
          'correlationId': _otherId,
          'source': 'local',
        })
        ..hear('search:done', {'correlationId': _otherId})
        ..hear(
          'exception',
          _refusal(403, 'Forbidden', 'Not you', correlationId: _otherId),
        )
        ..hear('search:done', null);
      await pumpEventQueue();

      expect(heard.answers, isEmpty);
      expect(heard.errors, isEmpty);
      expect(heard.done, isFalse);
    });

    test('each failure frame lands in its set', () async {
      final heard = _Heard(channel.search('catan'));

      hear('search:error', {'source': 'dg_igdb', 'message': 'Unknown error'});
      hear('search:rate_limited', {
        'source': 'dg_steam',
        'retryAfter': 60,
        'message': 'Too many requests',
      });
      hear('search:unavailable', {'source': 'dg_down'});
      hear('search:unfilterable', {'source': 'dg_bgg'});
      await pumpEventQueue();

      expect(heard.answers, hasLength(4));
      expect(
        heard.answers.last,
        _answer(
          const GameSearchResults(
            failedDataGateways: {'dg_igdb'},
            rateLimitedDataGateways: {'dg_steam'},
            unavailableDataGateways: {'dg_down'},
            unfilterableDataGateways: {'dg_bgg'},
          ),
        ),
      );
    });

    test(
      'a coordinator error marks the answer cut short and keeps listening',
      () async {
        final heard = _Heard(channel.search('catan'));

        heardResult('local', [_localGame()]);
        hear('search:error', {
          'source': 'coordinator',
          'message': 'Searching the data sources failed',
        });
        hear('search:source_done', {'source': 'local'});
        hear('search:done');
        await pumpEventQueue();

        expect(
          [for (final answer in heard.answers) (answer.cutShort, answer.done)],
          [(false, false), (true, false), (true, false), (true, true)],
        );
        expect(
          heard.answers.last.results.failedDataGateways,
          isEmpty,
          reason: 'the coordinator is not a DataGateway',
        );
        expect(heard.errors, isEmpty);
        expect(heard.done, isTrue);
      },
    );

    test(
      "a local error finishes this server's half with nothing, and the "
      'search goes on',
      () async {
        // As REST reads the same failure: an empty local half (#473).
        final heard = _Heard(channel.search('catan'));

        hear('search:error', {
          'source': 'local',
          'message': 'Searching this server failed',
        });
        // What the server sends after it, in a finally: it changes nothing.
        hear('search:source_done', {'source': 'local'});
        heardResult('dg_bgg', [_gatewayGame()]);
        hear('search:done');
        await pumpEventQueue();

        final found = GameSearchResults(
          byDataGateway: {
            'dg_bgg': [mapSearchHit(_gatewayGame())],
          },
        );
        expect(heard.answers, [
          _answer(const GameSearchResults(), localDone: true),
          _answer(found, localDone: true),
          _answer(found, localDone: true, done: true),
        ]);
        expect(heard.errors, isEmpty);
        expect(heard.done, isTrue);
        expect(lease.cancels, isEmpty, reason: 'the search goes on');
      },
    );

    test('a summary on a frame reaches the hit (#558)', () async {
      final heard = _Heard(channel.search('catan'));

      heardResult('dg_bgg', [_gatewayGame(summary: '**Big** box')]);
      await pumpEventQueue();

      expect(
        heard.answers.single.results.byDataGateway['dg_bgg']!.single.summary,
        '**Big** box',
      );
    });

    test('search:done ends the stream with done', () async {
      final heard = _Heard(channel.search('catan'));

      heardResult('local', [_localGame()]);
      hear('search:source_done', {'source': 'local'});
      hear('search:done');
      await pumpEventQueue();

      expect(
        heard.answers.last,
        _answer(
          GameSearchResults(local: [mapSearchHit(_localGame())]),
          localDone: true,
          done: true,
        ),
      );
      expect(heard.done, isTrue);
      expect(lease.listened, isFalse, reason: 'it stops listening');
      expect(lease.cancels, isEmpty, reason: 'the server has finished it');
    });

    test('a frame it cannot read fails the search as permanent', () async {
      final heard = _Heard(channel.search('catan'));

      heardResult('local', [_localGame()]);
      hear('search:result', {
        'source': 'dg_bgg',
        'games': [
          {'externalId': '926'},
        ],
      });
      await pumpEventQueue();

      expect(heard.answers, hasLength(1));
      expect(heard.errors.single, isA<GamesRemotePermanentException>());
      expect(heard.done, isTrue);
      expect(lease.cancels, [
        {'correlationId': _id},
      ], reason: 'the server is still searching');
      expect(lease.listened, isFalse);
    });
  });

  group('failures', () {
    test(
      "a 403 exception is GamesForbiddenException with the server's message",
      () async {
        final heard = _Heard(channel.search('catan'));

        lease.hear(
          'exception',
          _refusal(
            403,
            'Forbidden',
            'Searching beyond this server is not available to you.',
          ),
        );
        await pumpEventQueue();

        expect(
          heard.errors.single,
          isA<GamesForbiddenException>()
              .having(
                (e) => e.apiMessage,
                'apiMessage',
                'Searching beyond this server is not available to you.',
              )
              .having((e) => e.statusCode, 'statusCode', 403)
              .having(
                (e) => e.message,
                'message',
                isNot(contains('not available to you')),
              ),
        );
        expect(heard.answers, isEmpty);
        expect(heard.done, isTrue);
        expect(lease.cancels, isEmpty, reason: 'a refused search never ran');
        expect(lease.listened, isFalse);
      },
    );

    test('a 429 exception is transient', () async {
      final heard = _Heard(channel.search('catan'));

      lease.hear(
        'exception',
        _refusal(429, 'Too Many Requests', 'Too many requests'),
      );
      await pumpEventQueue();

      expect(
        heard.errors.single,
        isA<GamesRemoteTransientException>().having(
          (e) => e.statusCode,
          'statusCode',
          429,
        ),
      );
      expect(heard.done, isTrue);
    });

    test('a 5xx exception is transient', () async {
      final heard = _Heard(channel.search('catan'));

      lease.hear(
        'exception',
        _refusal(500, 'Internal Server Error', 'Something went wrong'),
      );
      await pumpEventQueue();

      expect(
        heard.errors.single,
        isA<GamesRemoteTransientException>().having(
          (e) => e.statusCode,
          'statusCode',
          500,
        ),
      );
    });

    // Read by the rules REST reads a status by (#473): 4xx a later search
    // can survive are transient there, and so here.
    test('a 401 exception is transient, as REST reads one', () async {
      final heard = _Heard(channel.search('catan'));

      lease.hear(
        'exception',
        _refusal(401, 'Unauthorized', 'Your session is invalid'),
      );
      await pumpEventQueue();

      expect(
        heard.errors.single,
        isA<GamesRemoteTransientException>().having(
          (e) => e.statusCode,
          'statusCode',
          401,
        ),
      );
      expect(heard.done, isTrue);
    });

    test('a 408 exception is transient, as REST reads one', () async {
      final heard = _Heard(channel.search('catan'));

      lease.hear('exception', _refusal(408, 'Request Timeout', 'Timed out'));
      await pumpEventQueue();

      expect(
        heard.errors.single,
        isA<GamesRemoteTransientException>().having(
          (e) => e.statusCode,
          'statusCode',
          408,
        ),
      );
    });

    test('a 409 the server says to retry is transient, as REST reads '
        'one', () async {
      final heard = _Heard(channel.search('catan'));

      // A deadlock's structured envelope, with the field REST reads.
      lease.hear('exception', {
        ..._refusal(409, 'Conflict', 'Try again'),
        'retryable': true,
      });
      await pumpEventQueue();

      expect(
        heard.errors.single,
        isA<GamesRemoteTransientException>().having(
          (e) => e.statusCode,
          'statusCode',
          409,
        ),
      );
    });

    test('a 400 exception is permanent', () async {
      final heard = _Heard(channel.search('catan'));

      // A validation failure's message is a list, as over HTTP.
      lease.hear(
        'exception',
        _refusal(400, 'Bad Request', ['query must be a string']),
      );
      await pumpEventQueue();

      expect(
        heard.errors.single,
        isA<GamesRemotePermanentException>().having(
          (e) => e.statusCode,
          'statusCode',
          400,
        ),
      );
      expect(heard.done, isTrue);
      expect(lease.cancels, isEmpty);
    });

    test('auth:error fails the search as transient', () async {
      final both = channelOver(lease, ids: _idsInTurn([_id, _otherId]));
      final first = _Heard(both.search('catan'));
      final second = _Heard(both.search('azul'));

      // It answers one frame, and ends the session's socket: every search on
      // it is over.
      lease.hear('auth:error', {
        'statusCode': 401,
        'error': 'Unauthorized',
        'message': 'Your session is invalid',
        'pattern': 'search:start',
        'correlationId': _otherId,
      });
      await pumpEventQueue();

      for (final heard in [first, second]) {
        expect(
          heard.errors.single,
          isA<GamesRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        );
        expect(heard.done, isTrue);
      }
      expect(
        lease.cancels,
        isEmpty,
        reason: 'the server is closing the socket',
      );
      expect(lease.listened, isFalse);
    });

    test('auth:error reports the session rejection and fails the search with '
        'a 401 transient', () async {
      var reports = 0;
      final reporting = channelOver(
        lease,
        onSessionRejected: () => reports += 1,
      );
      final heard = _Heard(reporting.search('catan'));

      lease.hear('auth:error', {
        'statusCode': 401,
        'error': 'Unauthorized',
        'message': 'Your session is invalid',
        'pattern': 'search:start',
        'correlationId': _id,
      });
      await pumpEventQueue();

      expect(reports, 1);
      expect(
        heard.errors.single,
        isA<GamesRemoteTransientException>().having(
          (e) => e.statusCode,
          'statusCode',
          401,
        ),
      );
      expect(heard.done, isTrue);
    });
  });

  group('ending early', () {
    test('a disconnect mid-search ends it cut short', () async {
      final heard = _Heard(channel.search('catan'));
      heardResult('local', [_localGame()]);
      hear('search:source_done', {'source': 'local'});
      await pumpEventQueue();

      lease.drop();
      await pumpEventQueue();

      expect(
        heard.answers.last,
        _answer(
          GameSearchResults(local: [mapSearchHit(_localGame())]),
          localDone: true,
          done: true,
          cutShort: true,
        ),
      );
      expect(heard.errors, isEmpty);
      expect(heard.done, isTrue);
      expect(lease.cancels, isEmpty);
      expect(lease.dropped, isEmpty, reason: 'the server cancels it itself');
    });

    test(
      'a disconnect before any answer is unavailable, so the search can go '
      'elsewhere',
      () async {
        final heard = _Heard(channel.search('catan'));
        // A frame of this search that changes no answer.
        hear('search:source_done', {'source': 'dg_bgg'});
        await pumpEventQueue();

        lease.drop();
        await pumpEventQueue();

        expect(heard.answers, isEmpty);
        expect(heard.errors.single, isA<RealtimeUnavailableException>());
        expect(heard.done, isTrue);
      },
    );

    test(
      "a disconnect before this server's half has finished is unavailable, "
      'though a DataGateway answered',
      () async {
        // Its answer holds no game of this server's, so a caller that waits
        // for them has shown nothing: cut short, the search would end
        // without them, and REST would never be asked.
        final heard = _Heard(channel.search('catan'));
        heardResult('dg_bgg', [_gatewayGame()]);
        await pumpEventQueue();
        expect(heard.answers.single.localDone, isFalse);

        lease.drop();
        await pumpEventQueue();

        expect(heard.answers, hasLength(1), reason: 'no answer after it');
        expect(heard.errors.single, isA<RealtimeUnavailableException>());
        expect(heard.done, isTrue);
      },
    );

    test(
      "the session's connection closing ends a search as a disconnect does",
      () async {
        final answered = channelOver(lease, ids: _idsInTurn([_id, _otherId]));
        final heard = _Heard(answered.search('catan'));
        final unanswered = _Heard(answered.search('azul'));
        heardResult('local', [_localGame()]);
        hear('search:source_done', {'source': 'local'});
        await pumpEventQueue();

        await lease.end();
        await pumpEventQueue();

        expect(heard.answers.last.cutShort, isTrue);
        expect(heard.answers.last.done, isTrue);
        expect(heard.done, isTrue);
        expect(unanswered.errors.single, isA<RealtimeUnavailableException>());
        expect(unanswered.done, isTrue);
      },
    );

    test('no frame for the idle timeout ends it cut short and cancels', () {
      // As long as a REST search waits for its answer.
      const timeout = GamesRemoteDataSourceImpl.searchReceiveTimeout;
      final almost = timeout - const Duration(seconds: 1);

      fakeAsync((async) {
        final quiet = _FakeLease();
        final searches = GameSearchChannelImpl(
          quiet,
          newCorrelationId: () => _id,
        );
        final heard = _Heard(searches.search('catan'));
        quiet
          ..hear('search:result', {
            'correlationId': _id,
            'source': 'local',
            'games': [_localGame()],
          })
          ..hear('search:source_done', {
            'correlationId': _id,
            'source': 'local',
          });
        async.elapse(almost);

        // A frame of this search restarts the wait; another's does not.
        quiet.hear('search:source_done', {
          'correlationId': _id,
          'source': 'dg_bgg',
        });
        async.elapse(almost);
        quiet.hear('search:source_done', {
          'correlationId': _otherId,
          'source': 'dg_bgg',
        });
        async.flushMicrotasks();

        expect(heard.done, isFalse);
        expect(quiet.cancels, isEmpty);

        async.elapse(const Duration(seconds: 1));

        expect(
          heard.answers.last,
          _answer(
            GameSearchResults(local: [mapSearchHit(_localGame())]),
            localDone: true,
            done: true,
            cutShort: true,
          ),
        );
        expect(heard.done, isTrue);
        expect(quiet.cancels, [
          {'correlationId': _id},
        ]);
        expect(quiet.listened, isFalse);
        expect(async.pendingTimers, isEmpty);

        unawaited(searches.close());
        async.flushMicrotasks();
      });
    });

    test(
      "no frame for the idle timeout before this server's half has finished "
      'fails the search as transient, as REST times out, and cancels it',
      () {
        // A server whose own query hangs, or that dropped the start without
        // a word: no answer to keep, so the caller falls back as it does when
        // REST waits as long.
        const timeout = GamesRemoteDataSourceImpl.searchReceiveTimeout;

        fakeAsync((async) {
          final quiet = _FakeLease();
          final searches = GameSearchChannelImpl(
            quiet,
            newCorrelationId: () => _id,
          );
          final heard = _Heard(searches.search('catan'));
          quiet.hear('search:result', {
            'correlationId': _id,
            'source': 'dg_bgg',
            'games': [_gatewayGame()],
          });
          async.elapse(timeout);

          expect(heard.answers, hasLength(1), reason: 'no answer after it');
          expect(
            heard.errors.single,
            isA<GamesRemoteTransientException>().having(
              (e) => e.statusCode,
              'statusCode',
              isNull,
            ),
          );
          expect(heard.done, isTrue);
          expect(quiet.cancels, [
            {'correlationId': _id},
          ]);
          expect(quiet.listened, isFalse);
          expect(async.pendingTimers, isEmpty);

          unawaited(searches.close());
          async.flushMicrotasks();
        });
      },
    );

    test('every way a search ends stops its idle wait', () {
      fakeAsync((async) {
        final quiet = _FakeLease();
        final searches = GameSearchChannelImpl(
          quiet,
          newCorrelationId: _idsInTurn(['done', 'cancelled', 'failed', 'gone']),
        );

        _Heard(searches.search('a'));
        quiet.hear('search:done', {'correlationId': 'done'});
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'done');

        unawaited(_Heard(searches.search('b')).cancel());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'cancelled');

        _Heard(searches.search('c'));
        quiet.hear(
          'exception',
          _refusal(400, 'Bad Request', 'x', correlationId: 'failed'),
        );
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'refused');

        final gone = _Heard(searches.search('d'));
        quiet.drop();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'disconnected');
        expect(gone.done, isTrue);
        expect(quiet.dropped, isEmpty, reason: 'nothing sent after the drop');

        unawaited(searches.close());
        async.flushMicrotasks();
      });
    });
  });

  group('cancelling and closing', () {
    test('cancelling the stream sends search:cancel once', () async {
      final heard = _Heard(channel.search('catan'));
      heardResult('local', [_localGame()]);
      await pumpEventQueue();

      await heard.cancel();
      expect(lease.listened, isFalse, reason: 'it stops listening');
      // A frame the server sent before it heard the cancel.
      hear('search:done');
      await pumpEventQueue();
      // The screen's close, after its search's.
      await channel.close();

      expect(lease.cancels, [
        {'correlationId': _id},
      ]);
      expect(heard.answers, hasLength(1), reason: 'nothing reaches it after');
      expect(lease.releases, 1);
    });

    test('cancelling after done sends nothing', () async {
      final heard = _Heard(channel.search('catan'));
      hear('search:done');
      await pumpEventQueue();

      await heard.cancel();
      await channel.close();

      expect(lease.sent.map((frame) => frame.event), ['search:start']);
    });

    test('close releases the lease', () async {
      await channel.close();
      await channel.close();

      expect(lease.releases, 1, reason: 'close is idempotent');
    });

    test(
      'close cancels a search still running, and ends its stream',
      () async {
        final heard = _Heard(channel.search('catan'));
        heardResult('local', [_localGame()]);
        await pumpEventQueue();

        await channel.close();
        await pumpEventQueue();

        expect(
          lease.cancels,
          [
            {'correlationId': _id},
          ],
          reason: 'sent before the lease is let go of',
        );
        expect(lease.releases, 1);
        expect(heard.done, isTrue);
        expect(heard.answers, hasLength(1), reason: 'no further answer');
        expect(heard.errors, isEmpty);
      },
    );

    test('a search after close is unavailable', () async {
      await channel.close();

      final heard = _Heard(channel.search('catan'));
      await pumpEventQueue();

      expect(heard.errors.single, isA<RealtimeUnavailableException>());
      expect(heard.done, isTrue);
      expect(
        lease.readies,
        0,
        reason: 'a closed channel asks its lease nothing',
      );
      expect(lease.sent, isEmpty);
      expect(lease.dropped, isEmpty);
    });
  });
}
