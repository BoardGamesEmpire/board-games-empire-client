import 'package:meta/meta.dart';
import 'package:models/domain.dart';

import 'package:network_interface/src/games_remote_data_source.dart';
import 'package:network_interface/src/realtime_connection.dart';

/// One answer so far from a game search that streams (#473): everything the
/// search has found up to now, and how far it has got.
///
/// A search's answers only grow. Each holds everything the one before it did,
/// and what came in since. A search over REST is the same stream with one
/// answer, [done] and [localDone] both set, so a caller reads both transports
/// one way.
@immutable
final class GameSearchProgress {
  const GameSearchProgress({
    required this.results,
    required this.localDone,
    required this.done,
    this.cutShort = false,
  });

  /// Everything the search has found so far: this server's half as
  /// [GameSearchResults.local], and each DataGateway's in the order its first
  /// result arrived, its own results in the order they came.
  final GameSearchResults results;

  /// Whether this server's own half has finished. It is the fast half, so a
  /// screen can show it while the DataGateways are still searching.
  ///
  /// A half that failed has finished too, having found nothing, which is how
  /// REST reads the same failure.
  final bool localDone;

  /// Whether this is the search's last answer.
  final bool done;

  /// Whether some results may be missing, because the search stopped short of
  /// hearing from every source.
  ///
  /// Set from the server's report that its search of the DataGateways failed
  /// as a whole, and on the last answer of a search that ended early: the
  /// connection dropped, or nothing came for too long.
  final bool cutShort;

  @override
  bool operator ==(Object other) =>
      other is GameSearchProgress &&
      other.results == results &&
      other.localDone == localDone &&
      other.done == done &&
      other.cutShort == cutShort;

  @override
  int get hashCode => Object.hash(results, localDone, done, cutShort);

  @override
  String toString() =>
      'GameSearchProgress(localDone: $localDone, done: $done, '
      'cutShort: $cutShort, results: $results)';
}

/// Opens [GameSearchChannel]s on the session's socket (#473).
///
/// The user-session scope registers one beside its [RealtimeConnection], when
/// the server has a socket to connect to. Without one, search goes over REST.
abstract interface class GameSearchStreamSource {
  /// A channel for one screen's searches.
  ///
  /// It takes a lease on the `games/search` namespace, which connects it if
  /// nothing else holds it. [GameSearchChannel.close] releases the lease.
  /// Throws [StateError] once the session's connection has closed, as
  /// [RealtimeConnection.lease] does.
  GameSearchChannel open();
}

/// One screen's game searches over the `games/search` socket (#473).
///
/// Each [search] streams its answers so far as the sources answer, so this
/// server's own results stop waiting on the DataGateways. The screen closes
/// the channel when it goes.
abstract interface class GameSearchChannel {
  /// Searches this server and, unless [includeExternal] is false, its
  /// DataGateways, as [GamesRemoteDataSource.search] does over REST, and
  /// streams each answer so far.
  ///
  /// The arguments are checked as REST checks them, so a search the server
  /// would refuse throws [ArgumentError] here, before anything is sent.
  ///
  /// Nothing is sent until the stream is listened to. Cancelling the
  /// subscription before the last answer cancels the search on the server.
  ///
  /// The stream ends after the answer with [GameSearchProgress.done]. A
  /// search that ends early once this server's half has finished
  /// ([GameSearchProgress.localDone]) ends that way too, marked
  /// [GameSearchProgress.cutShort], keeping what it found. It fails instead
  /// with:
  ///
  /// - [RealtimeUnavailableException] when the socket can't serve the search,
  ///   only ever before this server's half has finished. Until then an
  ///   answer holds only DataGateways' results, so a caller that waits for
  ///   this server's half before it shows any searches over REST instead,
  ///   having shown nothing yet.
  /// - [GamesForbiddenException] when the server refuses the search, with the
  ///   server's own words as [GamesForbiddenException.apiMessage]. A caller
  ///   that asked the DataGateways asks again without them (#795).
  /// - [GamesRemoteTransientException] or [GamesRemotePermanentException]
  ///   otherwise. Any other refusal is read by its status, by the rules a
  ///   failed REST request's is: a 401, 407, 408 or 429, a 409 the server
  ///   says to retry, a 5xx, or no status at all is transient, and any other
  ///   4xx permanent. The server ending the session is transient, as REST's
  ///   401 is, and so is a search that hears nothing for as long as a REST
  ///   search waits before this server's half has finished, as REST's
  ///   timeout is. An answer this client can't read is permanent, as an
  ///   unreadable REST body is.
  Stream<GameSearchProgress> search(
    String query, {
    int limit = GamesRemoteDataSource.searchPageSize,
    int offset = 0,
    GameSearchFilter filter = const GameSearchFilter(),
    bool includeExternal = true,
  });

  /// Releases the channel's lease, so the namespace disconnects when nothing
  /// else holds it.
  ///
  /// A search still running is cancelled on the server first, and its stream
  /// ends with no further answer. A search started after this fails with
  /// [RealtimeUnavailableException]. Idempotent.
  Future<void> close();
}
