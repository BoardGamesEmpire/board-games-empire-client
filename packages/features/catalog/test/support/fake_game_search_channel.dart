import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'fake_games_remote.dart';

/// A [GameSearchChannel] whose every search the test answers by hand (#473).
///
/// Each search records `search(…)` in [calls], as [FakeGamesRemote] records a
/// REST search, and joins [searches], whose controller its answers come
/// through. A search its listener cancels before it ends records `cancel(…)`
/// in [calls] too, so a test reads what was cancelled, and when, against the
/// searches around it.
class FakeGameSearchChannel implements GameSearchChannel {
  final List<String> calls = [];

  /// Every search asked for, in order.
  final List<FakeChannelSearch> searches = [];

  /// Runs as each search's stream is listened to, which is when the real
  /// channel starts a search: a test can answer or fail it at once.
  void Function(FakeChannelSearch search)? onListen;

  /// How many times [close] was called.
  int closes = 0;

  /// Whether [close] was called.
  bool get closed => closes > 0;

  @override
  Stream<GameSearchProgress> search(
    String query, {
    int limit = GamesRemoteDataSource.searchPageSize,
    int offset = 0,
    GameSearchFilter filter = const GameSearchFilter(),
    bool includeExternal = true,
  }) {
    final search = FakeChannelSearch._(
      this,
      describeSearch(query, filter, includeExternal: includeExternal),
    );
    calls.add('search(${search.described})');
    searches.add(search);
    return search.controller.stream;
  }

  /// What [close] throws, after counting the call, when set.
  Error? closeError;

  @override
  Future<void> close() async {
    closes++;
    if (closeError case final error?) throw error;
  }
}

/// One search on a [FakeGameSearchChannel], answered by hand.
final class FakeChannelSearch {
  FakeChannelSearch._(this._channel, this.described);

  final FakeGameSearchChannel _channel;

  /// The search as [describeSearch] puts it.
  final String described;

  /// Whether its listener cancelled it before it ended.
  bool cancelled = false;

  /// Its answers, which the test adds, directly or through [answer] and
  /// [fail].
  late final StreamController<GameSearchProgress> controller = StreamController(
    onListen: () => _channel.onListen?.call(this),
    onCancel: () {
      // A stream that ended was not cancelled, though delivering its
      // end cancels the subscription too.
      if (controller.isClosed) return;
      cancelled = true;
      _channel.calls.add('cancel($described)');
    },
  );

  /// Answers with everything found so far. The answer that is [done] ends
  /// the stream, as the real channel's last answer does.
  void answer(
    GameSearchResults results, {
    bool localDone = false,
    bool done = false,
    bool cutShort = false,
  }) {
    controller.add(
      GameSearchProgress(
        results: results,
        localDone: localDone,
        done: done,
        cutShort: cutShort,
      ),
    );
    if (done) unawaited(controller.close());
  }

  /// Fails the search with [error], which ends its stream, as the real
  /// channel's failures do.
  void fail(Object error) {
    controller.addError(error);
    unawaited(controller.close());
  }
}
