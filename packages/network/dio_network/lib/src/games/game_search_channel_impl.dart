import 'dart:async';

import 'package:dio_network/src/games/game_search_wire.dart';
import 'package:dio_network/src/games/games_remote_data_source_impl.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// The `games/search` socket's names (#473): its namespace, the events a
/// search sends and hears, and the sources the server names its own halves
/// by.
///
/// Backend `a691328f`. The namespace is `GameSearchGateway`'s, in
/// `apps/api/src/app/gateways/game/search.gateway.ts`, which also names the
/// two sources. The search events are `SearchEvents`, in
/// `libs/api/game-search/src/lib/constants/search-events.constant.ts`, with
/// their payloads in `search-outbound.dto.ts`. `exception` and `auth:error`
/// are `WsErrorEvents`, in
/// `libs/common/shared/src/lib/interfaces/ws-error.interface.ts`, on which
/// `WsErrorFilter` answers a refused frame.
abstract final class _Wire {
  static const String namespace = 'games/search';

  // Sent.
  static const String start = 'search:start';
  static const String cancel = 'search:cancel';

  // Heard, each tagged with the search's correlation id.
  static const String result = 'search:result';
  static const String sourceDone = 'search:source_done';
  static const String error = 'search:error';
  static const String rateLimited = 'search:rate_limited';
  static const String unavailable = 'search:unavailable';
  static const String unfilterable = 'search:unfilterable';
  static const String done = 'search:done';

  /// A refused frame, echoing the frame's correlation id. The socket stays
  /// open.
  static const String exception = 'exception';

  /// A frame from a session that has ended, which is a 401. The server
  /// closes the socket right after.
  static const String authError = 'auth:error';

  /// The source this server's own half answers as.
  static const String local = 'local';

  /// The source of a failure of the DataGateway half as a whole.
  static const String coordinator = 'coordinator';
}

/// Opens a [GameSearchChannelImpl] on the session's [RealtimeConnection]
/// (#473).
///
/// `RealtimeInstaller` registers one in the user-session scope, beside the
/// connection, so each screen's channel rides the session's one socket.
final class GameSearchStreamSourceImpl implements GameSearchStreamSource {
  const GameSearchStreamSourceImpl(this._connection);

  final RealtimeConnection _connection;

  @override
  GameSearchChannel open() =>
      GameSearchChannelImpl(_connection.lease(_Wire.namespace));
}

/// [GameSearchChannel] over one lease on the `games/search` namespace
/// (#473).
///
/// ## One search
///
/// A search sends `search:start` with a correlation id of its own. It asks
/// this server's catalog always, and the DataGateways unless told not to.
/// Its arguments are checked and named as REST's are, through the shared
/// search wire, except that a filter's sets go as arrays. The server tags
/// each of the search's frames with its id, so searches sharing the lease
/// never hear each other's. Two frames end every search: `auth:error`, and
/// the lease's [RealtimeLease.disconnectEvent].
///
/// Each frame feeds the answer so far, a [GameSearchResults] whose fields
/// mean what they mean over REST. Each game goes through [mapSearchHit],
/// REST's mapper, so #558's summary arrives the same both ways.
///
/// - `search:result`: `local`'s games join [GameSearchResults.local], and
///   any other source's join its entry in [GameSearchResults.byDataGateway],
///   keyed in the order each source's first games came.
/// - `search:source_done`: `local`'s sets [GameSearchProgress.localDone]. A
///   DataGateway's changes nothing.
/// - `search:error`: a DataGateway joins
///   [GameSearchResults.failedDataGateways]. `coordinator`, the DataGateway
///   half failing as a whole, sets [GameSearchProgress.cutShort], and the
///   search goes on for this server's half.
///
///   `local`, this server's half failing, finishes that half with no results:
///   it sets [GameSearchProgress.localDone], and the search goes on for the
///   DataGateways. That is how REST reads the same failure at backend
///   `a691328f`, answering an empty local half
///   (`libs/api/game-search/src/lib/game-search.service.ts:123-129`). The
///   socket sends the error, then `local`'s `search:source_done`, and keeps
///   going (`apps/api/src/app/gateways/game/search.gateway.ts:218-231`), so
///   the two transports answer alike (#473). The error's message isn't kept.
/// - `search:rate_limited`, `search:unavailable` and `search:unfilterable`:
///   the DataGateway joins [GameSearchResults.rateLimitedDataGateways],
///   [GameSearchResults.unavailableDataGateways] or
///   [GameSearchResults.unfilterableDataGateways]. The last is that
///   DataGateway's last frame.
/// - `search:done`: the last answer, with [GameSearchProgress.done].
///
/// The stream answers again after every frame that changes the answer, and
/// never mutates an answer it has given.
///
/// ## How a search ends
///
/// - **`search:done`** answers last. The server has finished the search, so
///   nothing is cancelled.
/// - **Ending early** answers last too, once this server's half has
///   finished, marked [GameSearchProgress.cutShort] and keeping what came.
///   Either the namespace dropped, or no frame of the search came for the
///   idle timeout. That is by default
///   [GamesRemoteDataSourceImpl.searchReceiveTimeout], as long as a REST
///   search waits. A quiet search is cancelled on the server. A dropped one
///   needs no cancel, since the server cancels every search of a connection
///   that goes.
/// - **A socket that can't serve before this server's half has finished**
///   fails the search with [RealtimeUnavailableException]: the lease can't
///   connect, or the namespace drops or the session's connection closes
///   first. Until then an answer holds only DataGateways' results, which a
///   caller waiting for this server's half, as the search screen does, has
///   not shown. So it loses nothing by searching over REST instead, and an
///   answer cut short there would leave out the server's own games.
/// - **No frame for the idle timeout before this server's half has
///   finished** fails the search as [GamesRemoteTransientException], as a
///   REST search that waits as long is, and cancels it. Its fast half has
///   said nothing, so what came is no answer to keep.
/// - **A refusal** comes on `exception`, which echoes the refused frame's
///   correlation id, in the HTTP error envelope, so its status is read by
///   the rules REST reads one by. A 403 is [GamesForbiddenException], with
///   the server's message as its `apiMessage`, so the caller can ask again
///   without the DataGateways (#795). A 401, 407, 408 or 429, a 409 the
///   server says to retry, or a 5xx is [GamesRemoteTransientException], and
///   any other 4xx [GamesRemotePermanentException]. The server never
///   registered a refused search, so nothing is cancelled.
/// - **`auth:error`** fails every search as transient, with status 401, as
///   REST reads a 401.
/// - **A frame this client can't read** fails the search as permanent, as an
///   unreadable REST body is, and cancels it.
/// - **Cancelling the subscription** before the end sends `search:cancel`,
///   once.
///
/// Every exception's message is this client's own account. The server's own
/// words go only into a 403's `apiMessage`. Whatever ends a search stops its
/// idle wait and its listening, and nothing reaches its stream after.
///
/// ## Closing
///
/// [close] cancels each search still running on the server, ends its stream
/// with no further answer, and then releases the lease.
final class GameSearchChannelImpl implements GameSearchChannel {
  GameSearchChannelImpl(
    this._lease, {
    this._idleTimeout = GamesRemoteDataSourceImpl.searchReceiveTimeout,
    this._newCorrelationId = uuidV4,
  });

  final RealtimeLease _lease;

  /// How long a search waits for its next frame before it ends cut short.
  final Duration _idleTimeout;

  /// Mints each search's correlation id: a UUID, which is all the server
  /// accepts. A seam for tests.
  final String Function() _newCorrelationId;

  /// The searches listened to that haven't ended.
  final Set<_Search> _running = {};

  bool _closed = false;

  @override
  Stream<GameSearchProgress> search(
    String query, {
    int limit = GamesRemoteDataSource.searchPageSize,
    int offset = 0,
    GameSearchFilter filter = const GameSearchFilter(),
    bool includeExternal = true,
  }) {
    checkSearchArguments(limit: limit, offset: offset, filter: filter);

    final correlationId = _newCorrelationId();
    return _Search(this, correlationId, {
      'correlationId': correlationId,
      'query': query,
      'limit': limit,
      'offset': offset,
      // This server's half is always asked for: it is the fast one.
      'includeLocal': true,
      'includeExternal': includeExternal,
      ...searchFilterFields(filter),
    }).answers;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Cancelled while the lease still holds the socket, so the cancels go
    // out even when this lease is the namespace's last.
    for (final search in [..._running]) {
      search.abandon();
    }
    await _lease.release();
  }
}

/// One search on a [GameSearchChannelImpl]: its stream of answers, and what
/// it has heard so far.
///
/// It starts when its stream is listened to, and ends exactly once, through
/// [_finish], by whichever comes first: its last answer, a failure, a
/// cancel, or the channel closing.
final class _Search {
  _Search(this._channel, this._id, this._start);

  final GameSearchChannelImpl _channel;
  final String _id;

  /// The `search:start` payload.
  final Map<String, Object?> _start;

  late final StreamController<GameSearchProgress> _answers =
      StreamController<GameSearchProgress>(
        onListen: _listened,
        onCancel: _cancelled,
      );

  StreamSubscription<RealtimeFrame>? _frames;
  Timer? _idle;

  /// Whether `search:start` went out, so the server may be running the
  /// search.
  bool _started = false;

  /// Set once the search has ended, however it did. Nothing is sent, heard or
  /// answered after.
  bool _ended = false;

  GameSearchResults _results = const GameSearchResults();
  bool _localDone = false;
  bool _cutShort = false;

  Stream<GameSearchProgress> get answers => _answers.stream;

  RealtimeLease get _lease => _channel._lease;

  /// Ends the search on the channel's close: cancelled on the server, and its
  /// stream ended with no further answer.
  void abandon() {
    if (_ended) return;
    _sendCancel();
    _finish();
  }

  void _listened() {
    if (_channel._closed) {
      _fail(
        const RealtimeUnavailableException(
          'This game search channel is closed',
        ),
      );
      return;
    }
    _channel._running.add(this);
    if (_lease.connected) {
      _begin();
    } else {
      unawaited(_awaitConnect());
    }
  }

  /// Waits for the namespace to connect, which takes no longer than a lease
  /// still connecting is allowed, and fails at once when it can't.
  Future<void> _awaitConnect() async {
    try {
      await _lease.ready();
    } on Object catch (error) {
      if (_ended) return;
      _fail(
        error is RealtimeUnavailableException
            ? error
            : RealtimeUnavailableException(
                'The games/search namespace could not connect',
                cause: error,
              ),
      );
      return;
    }
    if (!_ended) _begin();
  }

  /// Listens for the search's frames, then starts it on the server.
  void _begin() {
    if (!_lease.connected) {
      // The namespace dropped while its connect was on its way here.
      _fail(
        const RealtimeUnavailableException(
          'The games/search namespace dropped before the search started',
        ),
      );
      return;
    }
    _frames = _lease.frames.listen(
      _heard,
      onDone: () => _lost(
        "The session's socket closed before this server's half answered",
        null,
      ),
    );
    _lease.emit(_Wire.start, _start);
    _started = true;
    _restartIdle();
  }

  void _heard(RealtimeFrame frame) {
    if (_ended) return;
    final (:event, :data) = frame;
    switch (event) {
      case RealtimeLease.disconnectEvent:
        _lost(
          "The games/search namespace dropped before this server's half "
          'answered',
          data,
        );
        return;
      case _Wire.authError:
        _fail(
          GamesRemoteTransientException(
            'Game search ended: the server no longer accepts this session',
            statusCode: 401,
            cause: data,
          ),
        );
        return;
    }
    // Every other frame names the search it is for.
    if (data is! Map || data['correlationId'] != _id) return;
    _restartIdle();
    if (event == _Wire.exception) {
      _fail(_refused(data));
      return;
    }
    try {
      _read(event, data);
    } on Object catch (error) {
      _fail(
        GamesRemotePermanentException(
          'Failed to read a game search $event frame: $error',
          cause: error,
        ),
        cancel: true,
      );
    }
  }

  /// Folds one of the search's frames into its answer, and answers again
  /// when the answer changed. An event this client doesn't know changes
  /// nothing.
  void _read(String event, Map<Object?, Object?> frame) {
    if (event == _Wire.done) {
      _answer(done: true);
      _finish();
      return;
    }

    final before = (_results, _localDone, _cutShort);
    switch (event) {
      case _Wire.result:
        _addGames(_source(frame), frame['games']! as List<Object?>);
      // This server's half failing finishes it with nothing found, as REST
      // reads it (see the class doc). Its source_done then changes nothing.
      case _Wire.sourceDone || _Wire.error when _source(frame) == _Wire.local:
        _localDone = true;
      case _Wire.error when _source(frame) == _Wire.coordinator:
        _cutShort = true;
      case _Wire.error:
        _results = _results.copyWith(
          failedDataGateways: {
            ..._results.failedDataGateways,
            _source(frame),
          },
        );
      case _Wire.rateLimited:
        _results = _results.copyWith(
          rateLimitedDataGateways: {
            ..._results.rateLimitedDataGateways,
            _source(frame),
          },
        );
      case _Wire.unavailable:
        _results = _results.copyWith(
          unavailableDataGateways: {
            ..._results.unavailableDataGateways,
            _source(frame),
          },
        );
      case _Wire.unfilterable:
        _results = _results.copyWith(
          unfilterableDataGateways: {
            ..._results.unfilterableDataGateways,
            _source(frame),
          },
        );
    }
    if ((_results, _localDone, _cutShort) != before) _answer();
  }

  static String _source(Map<Object?, Object?> frame) =>
      frame['source']! as String;

  /// Adds [games] to [source]'s results. Each list is replaced, never grown
  /// in place, so an answer already given keeps what it held.
  void _addGames(String source, List<Object?> games) {
    final hits = [
      for (final game in games.cast<Map<String, dynamic>>()) mapSearchHit(game),
    ];
    if (hits.isEmpty) return;
    _results = source == _Wire.local
        ? _results.copyWith(
            local: List<GameSearchHit>.unmodifiable([
              ..._results.local,
              ...hits,
            ]),
          )
        : _results.copyWith(
            byDataGateway: {
              ..._results.byDataGateway,
              source: List<GameSearchHit>.unmodifiable([
                ...?_results.byDataGateway[source],
                ...hits,
              ]),
            },
          );
  }

  /// The failure a refused `search:start` stands for, read from the envelope
  /// `WsErrorFilter` sends: `{statusCode, error, message, pattern,
  /// correlationId}`, whose `message` is a list for a validation failure.
  ///
  /// That is the HTTP error envelope, so its status is read by the rules a
  /// failed REST request's is ([remoteVerdictFor]): what a later search can
  /// survive is transient. A 403 is [GamesForbiddenException] with the
  /// server's message, as REST's is, and any other refusal permanent.
  static GamesRemoteException _refused(Map<Object?, Object?> envelope) {
    final status = envelope['statusCode'];
    if (status is! int) {
      return GamesRemoteTransientException(
        'Game search was refused without a status',
        cause: envelope,
      );
    }
    final message = 'Game search was refused with status $status';
    if (remoteVerdictFor(status, body: envelope).isTransient) {
      return GamesRemoteTransientException(
        message,
        statusCode: status,
        cause: envelope,
      );
    }
    if (status == 403) {
      return GamesForbiddenException(
        message,
        statusCode: status,
        cause: envelope,
        apiMessage: apiErrorField(envelope, 'message'),
      );
    }
    return GamesRemotePermanentException(
      message,
      statusCode: status,
      cause: envelope,
    );
  }

  void _answer({bool done = false}) {
    _answers.add(
      GameSearchProgress(
        results: _results,
        localDone: _localDone,
        done: done,
        cutShort: _cutShort,
      ),
    );
  }

  /// The namespace went, or the session's connection closed under the lease.
  /// The server has cancelled the search with it.
  ///
  /// Before this server's half has finished, the search is unavailable,
  /// whatever the DataGateways sent: see the class doc.
  void _lost(String why, Object? cause) {
    if (_ended) return;
    if (!_localDone) {
      _fail(RealtimeUnavailableException(why, cause: cause));
      return;
    }
    _cutShort = true;
    _answer(done: true);
    _finish();
  }

  void _restartIdle() {
    _idle?.cancel();
    _idle = Timer(_channel._idleTimeout, _idled);
  }

  /// No frame of the search came for the idle timeout. Before this server's
  /// half has finished, that fails the search, as a REST search's timeout
  /// does: see the class doc.
  void _idled() {
    if (_ended) return;
    if (!_localDone) {
      _fail(
        GamesRemoteTransientException(
          'Game search timed out: nothing came of it for '
          '${_channel._idleTimeout}',
        ),
        cancel: true,
      );
      return;
    }
    _sendCancel();
    _cutShort = true;
    _answer(done: true);
    _finish();
  }

  void _fail(Object error, {bool cancel = false}) {
    if (cancel) _sendCancel();
    _answers.addError(error);
    _finish();
  }

  /// The subscription was cancelled: the stream has no listener left.
  void _cancelled() {
    if (_ended) return;
    _sendCancel();
    _finish(closeAnswers: false);
  }

  void _sendCancel() {
    if (_started) _lease.emit(_Wire.cancel, {'correlationId': _id});
  }

  /// Ends the search: no idle wait, no listening, and, unless its listener
  /// has gone already, a closed stream.
  void _finish({bool closeAnswers = true}) {
    _ended = true;
    _idle?.cancel();
    unawaited(_frames?.cancel());
    _channel._running.remove(this);
    if (closeAnswers) unawaited(_answers.close());
  }
}
