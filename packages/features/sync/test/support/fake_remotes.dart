import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// One household create as the sender sent it.
typedef HouseholdCreate = ({
  String name,
  String clientRequestId,
  String? description,
});

/// A household remote that answers creates from [respond] and records each
/// one. A create is the only household call the sender makes.
class FakeHouseholdRemote implements HouseholdRemoteDataSource {
  FakeHouseholdRemote(this.respond);

  /// Swappable mid-test, so a server can change its answer.
  FutureOr<Household> Function(HouseholdCreate create) respond;

  final List<HouseholdCreate> creates = [];

  @override
  Future<Household> createHousehold({
    required String name,
    required String clientRequestId,
    String? description,
    String? image,
    String? language,
    String? visibility,
  }) async {
    final create = (
      name: name,
      clientRequestId: clientRequestId,
      description: description,
    );
    creates.add(create);
    return respond(create);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not a send');
}

/// One collection write as the sender sent it: the method, the entry id it
/// named (null for an add), and the fields it carried.
typedef CollectionWrite = ({
  String method,
  String? id,
  Map<String, Object?> fields,
});

/// A collection remote that answers the three writes from [respond] and
/// records each one. Reads are not a send, so they throw.
class FakeCollectionRemote implements GameCollectionRemoteDataSource {
  FakeCollectionRemote(this.respond);

  /// Swappable mid-test, so a server can change its answer.
  FutureOr<GameCollection> Function(CollectionWrite write) respond;

  final List<CollectionWrite> writes = [];

  Future<GameCollection> _write(CollectionWrite write) async {
    writes.add(write);
    return respond(write);
  }

  @override
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    String? releaseId,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
  }) => _write((
    method: 'POST',
    id: null,
    fields: {
      'platformGameId': platformGameId,
      'medium': medium,
      'quantity': quantity,
      'rating': rating,
      'comment': comment,
    },
  ));

  @override
  Future<GameCollection> updateEntry({
    required String id,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
    String? releaseId,
  }) => _write((
    method: 'PATCH',
    id: id,
    fields: {
      'quantity': quantity,
      'rating': rating,
      'comment': comment,
      'favorite': favorite,
      'playAgain': playAgain,
    },
  ));

  @override
  Future<GameCollection> removeEntry(String id, {String? reason}) =>
      _write((method: 'DELETE', id: id, fields: const {}));

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not a send');
}
