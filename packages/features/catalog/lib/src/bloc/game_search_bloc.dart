import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/src/bloc/debounce_restartable.dart';
import 'package:game_catalog/src/bloc/game_search_event.dart';
import 'package:game_catalog/src/bloc/game_search_state.dart';
import 'package:game_catalog/src/search/data_gateway_search_grant.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Drives the search screen (#42): one page of a game search, shown in two
/// sections.
///
/// ## One page, as it arrives
///
/// The search asks for one page and shows what comes back. There is no "load
/// more": the server puts no order on its local half and sends no has-more
/// signal, so a second page could repeat or skip results (backend#792).
///
/// Given a [GameSearchChannel], the page streams in over the server's socket
/// as each source answers, so this server's own results stop waiting on the
/// DataGateways (#473). [GameSearchLoading] lasts until this server's half
/// has finished, which is the fast one, and each answer from then on is
/// shown as it comes, [GameSearchReady.searching] until the last. The
/// DataGateways' results wait for that half: one for a game the server holds
/// would otherwise show, then go when the server's half listed the game. A
/// search that stops short of hearing from every source keeps what it found,
/// marked [GameSearchReady.cutShort]: the connection dropped, nothing came
/// for too long, or the server's search of the DataGateways failed as a
/// whole. Every answer that came over the socket is
/// [GameSearchReady.streamed], its last included, so the screen can tell it
/// from one that came whole. The bloc owns the channel, and closes it with
/// itself.
///
/// Without a channel, or when the socket can't serve a search before this
/// server's half has answered, the search goes over REST, as one finished
/// answer, not streamed. Nothing of it is on screen by then, as a
/// DataGateway's answer waits for that half. The server waits for every
/// DataGateway, for up to 15 seconds, before it answers, so
/// [GameSearchLoading] can last that long there.
///
/// ## Two sections
///
/// [GameSearchReady.onServer] is the server's own half. Every DataGateway's
/// results follow, in [GameSearchReady.fromSources], less any game the
/// first section already lists: the server reports a game it imported both
/// as its own and again under the DataGateway it came from (backend#662).
/// Each DataGateway's results stay together, in the order
/// [GameSearchResults.byDataGateway] holds them, so one that arrives later
/// joins the end of its own DataGateway's run (#473).
///
/// Each section lists a result once. A result its source sends again, by
/// the same `externalId`, is dropped where it repeats, and the first copy
/// stands for both. The screen keys its rows by those ids, and a keyed list
/// needs each key once, but nothing below the bloc drops a repeat (#473).
///
/// A DataGateway is named only where `sourceNames` can name it. The shell
/// passes one only when the user may read DataGateways, which ordinary users
/// may not (#42). Without it, a result carries no source name, and the note
/// on DataGateways that did not answer counts them instead of naming them.
///
/// ## Typing, filtering and the order of answers
///
/// Query changes are debounced, and a new one cancels the handler still
/// waiting on an older one (`restartable()`). A filter change and a retry
/// start a search of their own, outside that ordering. A filter change that
/// narrows the search no differently, such as keeping unknown values on a
/// range with no bound, starts none: the state takes the new filter, for
/// its controls, and nothing else changes. So every search
/// takes a sequence number, and an answer that lands after a newer search
/// started is dropped, as `DataGatewayListBloc`'s reads are.
///
/// Each search also cancels the stream of the one before it, whichever event
/// started either, so the server stops a search no one is waiting for and
/// no more of its answers arrive (#473). A REST request can't be cancelled:
/// the sequence number drops its answer.
///
/// A query change whose text, trimmed, is what is already shown searches
/// nothing. Nor does one that arrives while the search for that text is
/// still running, its answers still arriving included: the change has
/// cancelled the handler that was showing them, so its own handler takes
/// that over, and waits for the search's end in its place. So a trailing
/// space neither clears the rows on screen nor asks the server again.
///
/// Clearing the text skips the debounce: the screen goes back to
/// [GameSearchIdle] at once, rather than showing the old text's results
/// under an empty field, and an answer still on its way for that text is
/// dropped.
///
/// ## A game found gone
///
/// A game that the server no longer has, or this user may no longer read,
/// is taken down from both sections when `gone` says so, and stays down
/// while this screen is open.
///
/// ## When the DataGateways are refused
///
/// A user who may read the server's games but not its DataGateways is
/// refused (403) by a search that asks for them (#795). So a search asks
/// them only while the session's [DataGatewaySearchGrant] says it may, and a
/// 403 on a search that asked is retried once without them. If the retry
/// answers, the session remembers the refusal, the answer is shown with
/// [GameSearchReady.dataGatewaysRefused] and the server's own
/// [GameSearchReady.refusalMessage], and later searches skip the DataGateways
/// from the start. A retry that is refused too is the refusal below; one
/// that fails otherwise is the failure below, and remembers nothing.
///
/// The socket's 403 means what REST's does, so a search over either is
/// retried the same way, and the retry, like any search, goes over the
/// socket where it can and REST where it can't (#473). The refusal is
/// remembered once the retry answers.
///
/// A retry over REST whose search has been superseded shows nothing, but
/// still remembers the refusal when it answers: the server did say it,
/// whoever is waiting. One over the socket is cancelled with its search, so
/// it remembers the refusal only if it had answered by then.
///
/// A search superseded before its 403 lands still retries, quietly and
/// always over REST: the 403 may be the catalog's, and a refused catalog is
/// forgotten whoever is waiting (#557). A stream followed for it would take
/// the newer search's place as the one the next search stops.
///
/// ## When the server refuses
///
/// A 403 on a search that left the DataGateways out says this user may not
/// read the server's games at all: the route checks that before it
/// searches. So the bloc reports [GameSearchDenied]
/// rather than searching the cache: the server's answer wins over an old
/// copy, as it does on the detail. The refusal also forgets this user's
/// catalog on this device, so offline browse and search show only the games
/// their collection reaches (#557). A failed forget is logged and otherwise
/// ignored.
///
/// ## When the search fails
///
/// The bloc searches the games cached on this device instead
/// ([GameRepository.searchGames]), narrowed by the whole filter by the
/// server's rules, and reports them as [GameSearchReady.fromCache]. Without a
/// cache, or when that read fails too, it reports [GameSearchFailed].
///
/// A stream that fails after its first answers fails the same way, and what
/// it showed gives way to the cache's answer (#473). One that ends early
/// has not failed: see "One page, as it arrives".
///
/// The cache holds no platform types, so a search narrowed by platform type
/// finds nothing there rather than showing games it cannot vouch for.
class GameSearchBloc extends Bloc<GameSearchEvent, GameSearchState> {
  GameSearchBloc({
    required this._remote,
    this._cache,
    this._stream,
    Future<Map<String, String>> Function()? sourceNames,
    Stream<String>? gone,
    DataGatewaySearchGrant? grant,
    Duration debounce = defaultDebounce,
    BgeLogger? logger,
  }) : _grant = grant ?? DataGatewaySearchGrant(),
       _logger = logger ?? BgeLogger('bge.catalog.search'),
       super(const GameSearchIdle()) {
    on<GameSearchQueryChanged>(
      _onQueryChanged,
      transformer: debounceRestartable(
        debounce,
        immediate: (event) => event.query.trim().isEmpty,
      ),
    );
    on<GameSearchFilterChanged>(_onFilterChanged);
    on<GameSearchRetryRequested>(_onRetryRequested);
    on<GameSearchSourceNamesLoaded>(_onSourceNamesLoaded);
    on<GameSearchGameGone>(_onGameGone);
    _goneSubscription = gone?.listen((id) => add(GameSearchGameGone(id)));

    if (sourceNames != null) unawaited(_loadSourceNames(sourceNames));
  }

  /// How long typing must pause before the text is searched for.
  static const Duration defaultDebounce = Duration(milliseconds: 400);

  final GamesRemoteDataSource _remote;
  final GameRepository? _cache;

  /// The channel this screen's searches stream over (#473). Null where they
  /// go over REST alone.
  final GameSearchChannel? _stream;
  final DataGatewaySearchGrant _grant;
  final BgeLogger _logger;

  /// The trimmed text being searched for. Empty when there is none.
  String _query = '';
  GameSearchFilter _filter = const GameSearchFilter();

  /// Which search is the latest. An older one that answers late is dropped.
  int _sequence = 0;

  /// Each DataGateway's name, by id. Empty until they arrive, and for good
  /// where they cannot be read.
  Map<String, String> _names = const {};

  /// The last answer shown, the server's or this device's, kept so names
  /// that arrive later, and games found gone, can be applied to it.
  GameSearchResults? _shown;

  /// Games found gone since this screen opened, never shown again.
  final Set<String> _gone = {};
  StreamSubscription<String>? _goneSubscription;

  /// The search whose answers are arriving, while one is. The next search
  /// cancels it, whichever event starts that one, and so does [close].
  _RunningSearch? _running;

  /// The latest search, from its start until its last state is shown, and
  /// the handler that shows its states.
  _Showing? _showing;

  /// Set as [close] begins, so a search that reaches the bloc while it
  /// closes opens no stream that [close] has already gone past.
  bool _closing = false;

  @override
  Future<void> close() async {
    _closing = true;
    // Whatever is still running is stale from here, as if a newer search
    // had started, so nothing more is shown.
    _sequence++;
    // Before the channel closes, so the server hears the cancel while the
    // channel still holds its lease.
    await _stopRunning();
    // A channel that fails to close is logged, not thrown: the screen's
    // provider doesn't await this, so a throw would reach the uncaught-error
    // hook and show the user a crash prompt for a screen they have left. The
    // bloc closes all the same.
    try {
      await _stream?.close();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Closing the game search channel failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await _goneSubscription?.cancel();
    await super.close();
  }

  Future<void> _loadSourceNames(
    Future<Map<String, String>> Function() read,
  ) async {
    try {
      final names = await read();
      if (!isClosed) add(GameSearchSourceNamesLoaded(names));
    } on Object catch (error, stackTrace) {
      // Unnamed results still read correctly; the note counts the
      // DataGateways that did not answer rather than naming them.
      _logger.info(
        "Could not read the DataGateways' names",
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _onQueryChanged(
    GameSearchQueryChanged event,
    Emitter<GameSearchState> emit,
  ) async {
    final query = event.query.trim();
    if (query == _query) {
      if (state case GameSearchReady(searching: false)) return;
      // Still running: this change has cancelled the handler showing it, so
      // this one shows the rest.
      final showing = _showing;
      if (showing != null && showing.search == _sequence) {
        await showing.handOver(emit);
        return;
      }
    }
    _query = query;
    await _search(emit);
  }

  Future<void> _onFilterChanged(
    GameSearchFilterChanged event,
    Emitter<GameSearchState> emit,
  ) async {
    final same = _asSearched(event.filter) == _asSearched(_filter);
    _filter = event.filter;
    if (same) {
      _keepFilter(emit);
      return;
    }
    await _search(emit);
  }

  /// [filter] as a search reads it: a range with no bound narrows nothing,
  /// so whether it keeps unknown values makes no difference (#565, #580).
  static GameSearchFilter _asSearched(GameSearchFilter filter) {
    GameSearchRange read(GameSearchRange range) =>
        range.narrows ? range : const GameSearchRange();
    return filter.copyWith(
      publishYear: read(filter.publishYear),
      playerCount: read(filter.playerCount),
      playTime: read(filter.playTime),
    );
  }

  /// Shows the current state again under [_filter], which narrows the
  /// search no differently, so the filter's controls read it. An answer is
  /// built again by [_ready], its one maker, so it keeps all it showed.
  void _keepFilter(Emitter<GameSearchState> emit) {
    final filter = _filter;
    switch (state) {
      case GameSearchReady():
        _showAgain(emit);
      case GameSearchIdle():
        emit(GameSearchIdle(filter: filter));
      case GameSearchLoading(:final query):
        emit(GameSearchLoading(query: query, filter: filter));
      case GameSearchFailed(:final query):
        emit(GameSearchFailed(query: query, filter: filter));
      case GameSearchDenied(:final query):
        emit(GameSearchDenied(query: query, filter: filter));
    }
  }

  Future<void> _onRetryRequested(
    GameSearchRetryRequested event,
    Emitter<GameSearchState> emit,
  ) => _search(emit);

  void _onSourceNamesLoaded(
    GameSearchSourceNamesLoaded event,
    Emitter<GameSearchState> emit,
  ) {
    _names = Map.unmodifiable(event.names);
    _showAgain(emit);
  }

  void _onGameGone(GameSearchGameGone event, Emitter<GameSearchState> emit) {
    if (_gone.add(event.gameId)) _showAgain(emit);
  }

  /// Shows the last answer again, with what has changed since applied.
  void _showAgain(Emitter<GameSearchState> emit) {
    final shown = _shown;
    final current = state;
    if (current is GameSearchReady && shown != null) {
      emit(
        _ready(
          shown,
          fromCache: current.fromCache,
          streamed: current.streamed,
          searching: current.searching,
          cutShort: current.cutShort,
        ),
      );
    }
  }

  Future<void> _search(Emitter<GameSearchState> emit) async {
    if (_closing) return;
    final search = ++_sequence;
    // Whichever event started this search, the stream of the one before it
    // stops here, and so does the server's search for it (#473).
    unawaited(_stopRunning());
    final query = _query;
    final filter = _filter;
    _shown = null;

    if (query.isEmpty) {
      emit(GameSearchIdle(filter: filter));
      return;
    }

    final showing = _showing = _Showing(search, emit);
    try {
      await _run(showing.show, search, query, filter);
    } finally {
      showing.end();
      if (identical(_showing, showing)) _showing = null;
    }
  }

  /// Runs search number [search], showing its states through [emit].
  Future<void> _run(
    _Show emit,
    int search,
    String query,
    GameSearchFilter filter,
  ) async {
    emit(GameSearchLoading(query: query, filter: filter));
    final asked = _grant.mayAsk;
    try {
      try {
        await _follow(
          emit,
          search: search,
          query: query,
          filter: filter,
          includeExternal: asked,
        );
      } on GamesForbiddenException catch (refusal) {
        // Only a search that asked the DataGateways can learn they are what
        // is refused. One that did not is refused the catalog.
        if (!asked) rethrow;
        if (search != _sequence) {
          // No one is waiting for this search, but its 403 may be the
          // catalog's, and only the retry tells: a 403 here too forgets the
          // catalog (#557), and an answer remembers the DataGateways'
          // refusal. Over REST, so the newer search's stream stays the one
          // the next search stops.
          await _remote.search(query, filter: filter, includeExternal: false);
          _grant.refuse(refusal.apiMessage);
          return;
        }
        await _follow(
          emit,
          search: search,
          query: query,
          filter: filter,
          includeExternal: false,
          // Remembered at the retry's first answer, before the sequence is
          // checked, so a search superseded while its retry ran over REST
          // still teaches the session what the server said: it is true of
          // the session, not of this search. What the retry found is shown
          // only if this is still the latest search. A retry that fails
          // before it answers remembers nothing.
          onAnswered: () => _grant.refuse(refusal.apiMessage),
        );
      }
    } on GamesForbiddenException {
      await _denied(emit, search, query);
    } on Object catch (error, stackTrace) {
      if (search != _sequence) return;
      _logger.warn(
        'Game search failed; searching this device instead',
        error: error,
        stackTrace: stackTrace,
      );
      await _searchCache(emit, search: search, query: query, filter: filter);
    }
  }

  /// Runs one search to its end, showing each answer as it comes: over the
  /// channel where there is one, and over REST, as one finished answer,
  /// where there isn't or the socket can't serve the search (#473).
  ///
  /// [onAnswered] runs at the search's first answer that shows, whichever
  /// way it came, before the sequence is checked. Throws what the search
  /// failed with, except a socket that couldn't serve it, which REST takes
  /// over from.
  Future<void> _follow(
    _Show emit, {
    required int search,
    required String query,
    required GameSearchFilter filter,
    required bool includeExternal,
    void Function()? onAnswered,
  }) async {
    final stream = _stream;
    if (stream != null) {
      final served = await _listen(
        emit,
        search,
        stream.search(query, filter: filter, includeExternal: includeExternal),
        onAnswered: onAnswered,
      );
      if (served || search != _sequence) return;
    }
    final results = await _remote.search(
      query,
      filter: filter,
      includeExternal: includeExternal,
    );
    onAnswered?.call();
    if (search != _sequence) return;
    _show(
      emit,
      GameSearchProgress(results: results, localDone: true, done: true),
      streamed: false,
    );
  }

  /// Follows [answers] until the stream ends, showing each as it comes, and
  /// runs [onAnswered] at the first that [_show] shows.
  ///
  /// Returns false when the socket couldn't serve the search: the stream
  /// failed with [RealtimeUnavailableException] before an answer [_show]
  /// shows, so none of it is on screen and REST can take over. The channel
  /// fails that way only before this server's half has finished, which is
  /// that answer, so a DataGateway's answer before it doesn't keep REST
  /// away. Throws any other failure. Returns at once, as if the stream had
  /// ended, when the next search or [close] cancels it.
  Future<bool> _listen(
    _Show emit,
    int search,
    Stream<GameSearchProgress> answers, {
    void Function()? onAnswered,
  }) async {
    var shown = false;
    final running = _running = _RunningSearch(answers, (progress) {
      if (!shown && _shows(progress)) {
        shown = true;
        onAnswered?.call();
      }
      if (search == _sequence) _show(emit, progress, streamed: true);
    });
    try {
      await running.ended;
      return true;
    } on RealtimeUnavailableException {
      if (shown) rethrow;
      return false;
    } finally {
      if (identical(_running, running)) _running = null;
    }
  }

  /// Shows [progress], the latest search's answer so far, from the first
  /// answer in which this server's own half has finished, or the search has:
  /// [GameSearchLoading] stays until then. [streamed] says it came over the
  /// socket rather than whole, over REST.
  ///
  /// So the DataGateways' rows wait for that half (#473). A DataGateway can
  /// report a game the server holds before the server's half lists it
  /// (backend#662): shown then, its row would go again once [_ready] took it
  /// out.
  void _show(
    _Show emit,
    GameSearchProgress progress, {
    required bool streamed,
  }) {
    if (!_shows(progress)) return;
    final GameSearchProgress(:results, :done, :cutShort) = progress;
    _shown = results;
    emit(
      _ready(
        results,
        fromCache: false,
        streamed: streamed,
        searching: !done,
        cutShort: cutShort,
      ),
    );
  }

  /// Whether [_show] shows [progress].
  static bool _shows(GameSearchProgress progress) =>
      progress.localDone || progress.done;

  /// Stops following the search whose answers are arriving, if one is,
  /// which cancels it on the server.
  Future<void> _stopRunning() async {
    final running = _running;
    if (running == null) return;
    _running = null;
    try {
      await running.cancel();
    } on Object catch (error, stackTrace) {
      // Its answers have stopped all the same: the subscription is gone.
      _logger.info(
        'Cancelling the running game search failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// The catalog is refused: shown as [GameSearchDenied].
  Future<void> _denied(
    _Show emit,
    int search,
    String query,
  ) async {
    // A stale 403 still says the catalog is refused.
    await _forgetCatalog();
    if (search != _sequence) return;
    // [_filter], not the filter searched with: one that narrows no
    // differently may have come in since, and the controls read it here,
    // as they do from [_ready].
    emit(GameSearchDenied(query: query, filter: _filter));
  }

  Future<void> _forgetCatalog() async {
    final cache = _cache;
    if (cache == null) return;
    try {
      await cache.forgetCatalog();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Forgetting the refused catalog failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _searchCache(
    _Show emit, {
    required int search,
    required String query,
    required GameSearchFilter filter,
  }) async {
    final cache = _cache;
    if (cache == null) {
      emit(GameSearchFailed(query: query, filter: _filter));
      return;
    }

    try {
      final games = await cache.searchGames(
        query,
        // The cache returns as many as an online page: the argument follows
        // that constant, not the repository default.
        // ignore: avoid_redundant_argument_values
        limit: GamesRemoteDataSource.searchPageSize,
        filter: filter,
      );
      if (search != _sequence) return;
      final results = GameSearchResults(
        local: [for (final game in games) _hitOf(game)],
      );
      _shown = results;
      emit(_ready(results, fromCache: true));
    } on Object catch (error, stackTrace) {
      if (search != _sequence) return;
      _logger.warn(
        'Searching this device failed too',
        error: error,
        stackTrace: stackTrace,
      );
      emit(GameSearchFailed(query: query, filter: _filter));
    }
  }

  /// A cached game, as a result from this server.
  static GameSearchHit _hitOf(Game game) => GameSearchHit(
    externalId: game.id,
    title: game.title,
    contentType: game.contentType,
    gameId: game.id,
    yearPublished: game.publishYear,
    minPlayers: game.minPlayers,
    maxPlayers: game.maxPlayers,
    thumbnailUrl: game.thumbnail,
  );

  GameSearchSource _source(String id) =>
      GameSearchSource(id: id, name: _names[id]);

  /// One source's [hits] with each `externalId` once, at its first copy's
  /// place, in their order.
  ///
  /// The screen keys a source's rows by `externalId`, and a keyed list needs
  /// each key once, but no layer below de-duplicates a source's hits (#473).
  /// A repeat is the same result, so the first copy stands for it, and the
  /// filters after this one read that copy.
  static List<GameSearchHit> _onceEach(List<GameSearchHit> hits) {
    final seen = <String>{};
    return [
      for (final hit in hits)
        if (seen.add(hit.externalId)) hit,
    ];
  }

  GameSearchReady _ready(
    GameSearchResults results, {
    required bool fromCache,
    bool streamed = false,
    bool searching = false,
    bool cutShort = false,
  }) {
    final onServerIds = {
      for (final hit in results.local)
        if (hit.gameId != null) hit.gameId,
    };

    return GameSearchReady(
      query: _query,
      filter: _filter,
      fromCache: fromCache,
      // The cache never asked the DataGateways, so it has no refusal to
      // report: it stands for the server being out of reach (#795).
      dataGatewaysRefused: !fromCache && !_grant.mayAsk,
      refusalMessage: fromCache ? null : _grant.serverMessage,
      streamed: streamed,
      searching: searching,
      cutShort: cutShort,
      onServer: [
        for (final hit in _onceEach(results.local))
          if (!_gone.contains(hit.gameId)) hit,
      ],
      fromSources: [
        for (final MapEntry(key: sourceId, value: hits)
            in results.byDataGateway.entries)
          for (final hit in _onceEach(hits))
            if (!onServerIds.contains(hit.gameId) &&
                !_gone.contains(hit.gameId))
              GameSearchSourceHit(source: _source(sourceId), hit: hit),
      ],
      // One note covers every way a DataGateway can fail to answer: the
      // screen tells the user some results may be missing, not why.
      missingSources: [
        for (final id in {
          ...results.failedDataGateways,
          ...results.rateLimitedDataGateways,
          ...results.unavailableDataGateways,
        })
          _source(id),
      ],
      unfilterableSources: [
        for (final id in results.unfilterableDataGateways) _source(id),
      ],
    );
  }
}

/// The search whose answers [GameSearchBloc] is following (#473): its
/// subscription, and the end its handler waits for.
final class _RunningSearch {
  _RunningSearch(
    Stream<GameSearchProgress> answers,
    void Function(GameSearchProgress progress) onAnswer,
  ) {
    // An error ends the search for the bloc, so nothing it sends after one
    // is heard.
    _subscription = answers.listen(
      onAnswer,
      onError: _ended.completeError,
      onDone: _ended.complete,
      cancelOnError: true,
    );
  }

  final Completer<void> _ended = Completer<void>();
  late final StreamSubscription<GameSearchProgress> _subscription;

  /// Completes when the stream ends, with its error if it failed, or when
  /// [cancel] stops it.
  Future<void> get ended => _ended.future;

  /// Stops following the search, which cancels it on the server, and lets
  /// the handler waiting on [ended] go on.
  Future<void> cancel() {
    // A stream that ended just now has completed it already.
    if (!_ended.isCompleted) _ended.complete();
    return _subscription.cancel();
  }
}

/// Shows one state of a search: [_Showing.show].
typedef _Show = void Function(GameSearchState state);

/// The latest search [GameSearchBloc] is running, and the handler whose
/// emitter shows its states (#473).
///
/// A query change for the text being searched cancels the handler showing
/// it (`restartable()`), whose emitter then drops every state. So that
/// change's own handler takes the search over with [handOver], rather than
/// starting it again.
final class _Showing {
  _Showing(this.search, this._emit);

  /// The search's sequence number.
  final int search;

  Emitter<GameSearchState> _emit;
  final Completer<void> _ended = Completer<void>();

  void show(GameSearchState state) => _emit(state);

  /// Shows the rest of the search through [emit], and completes once its
  /// last state is shown, so [emit]'s handler stays open until then.
  Future<void> handOver(Emitter<GameSearchState> emit) {
    _emit = emit;
    return _ended.future;
  }

  /// The search has shown its last state.
  void end() {
    if (!_ended.isCompleted) _ended.complete();
  }
}
