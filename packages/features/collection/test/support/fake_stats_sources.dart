import 'dart:async';

import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [HouseholdRemoteDataSource] that answers only for the game pool, as the
/// test scripts. Every other call is a test reaching a route it never meant to.
class FakeGamePool implements HouseholdRemoteDataSource {
  /// The size of each read, in order.
  final List<int> reads = [];

  /// Answers every read. Unset, the pool holds [GamePoolSample.gameCount] of 0.
  Future<GamePoolSample> Function(int size)? onSample;

  /// Every read answers a pool of [gameCount] games.
  void answer(int gameCount) =>
      onSample = (_) async =>
          (games: const <GameSummary>[], gameCount: gameCount);

  /// Every read fails.
  void fail() => onSample = (_) async => throw StateError('the read failed');

  @override
  Future<GamePoolSample> fetchGamePoolSample({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) {
    reads.add(size);
    return onSample?.call(size) ??
        Future.value((games: const <GameSummary>[], gameCount: 0));
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

  /// Whether anything is listening to the collection.
  bool get listened => _items.hasListener;

  /// The collection now holds [items].
  void emit(List<GameCollectionListItem> items) => _items.add(items);

  /// The stream fails.
  void fail() => _items.addError(StateError('the collection failed'));

  /// The stream closes, as disposing the repository closes it.
  Future<void> close() => _items.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A household, for a stream of them.
Household household(String id) => Household(
  id: id,
  name: 'Household $id',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
