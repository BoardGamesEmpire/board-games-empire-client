import 'dart:async';

import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [HouseholdRemoteDataSource] that answers only for the game pool, as the
/// test scripts. Every other call is a test reaching a route it never meant to.
class FakeGamePool implements HouseholdRemoteDataSource {
  /// The size of each read, in order.
  final List<int> reads = [];

  /// Answers every read. Unset, the pool is empty.
  Future<GamePoolSample> Function(int size)? onSample;

  @override
  Future<GamePoolSample> fetchGamePoolSample({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) {
    reads.add(size);
    return onSample?.call(size) ?? Future.value(poolOf(const []));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [GameCollectionRepository] whose only stream the test drives by hand.
///
/// Like the real one, it closes rather than errors when disposed: see [close].
class FakeOwnGames implements GameCollectionRepository {
  final _items = StreamController<List<GameCollectionListItem>>.broadcast();

  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() =>
      _items.stream;

  /// The collection now holds [items].
  void emit(List<GameCollectionListItem> items) => _items.add(items);

  /// The stream fails.
  void fail() => _items.addError(StateError('the collection failed'));

  /// The stream closes, as disposing the repository closes it.
  Future<void> close() => _items.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A sampled game, as the server sends one.
GameSummary summary(String id) => GameSummary(id: id, title: 'Game $id');

/// The pool's answer, holding one game per id in [ids].
GamePoolSample poolOf(List<String> ids) =>
    (games: [for (final id in ids) summary(id)], gameCount: ids.length);

/// One collection entry of the game [gameId]. Name [entryId] for a second entry
/// of the same game.
GameCollectionListItem ownItem(
  String gameId, {
  String? entryId,
  GameMedium medium = GameMedium.physical,
  String? title,
  String? subtitle,
  String? thumbnail,
}) => GameCollectionListItem(
  entry: GameCollection(
    id: entryId ?? 'entry-$gameId',
    userId: 'user-1',
    platformGameId: 'pg-$gameId',
    medium: medium,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  gameId: gameId,
  title: title ?? 'Game $gameId',
  subtitle: subtitle,
  platformName: 'Board game',
  thumbnail: thumbnail,
);

/// A household, for a stream of them.
Household household(String id) => Household(
  id: id,
  name: 'Household $id',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
