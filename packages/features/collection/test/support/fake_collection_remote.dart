import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// What the hydrate asked for in one list request.
typedef CollectionListRequest = ({
  int page,
  int limit,
  bool includeDeleted,
  DateTime? updatedSince,
});

/// A collection remote that answers list requests from [respond] and records
/// each one. The list read is the only call a hydrate makes; anything else
/// throws.
class FakeCollectionRemote implements GameCollectionRemoteDataSource {
  FakeCollectionRemote(this.respond);

  /// Swappable mid-test, so a server can "come back".
  FutureOr<PaginatedResult<GameCollectionWithSummary>> Function(
    CollectionListRequest request,
  )
  respond;

  final List<CollectionListRequest> requests = [];

  @override
  Future<PaginatedResult<GameCollectionWithSummary>> fetchCollectionPage({
    int page = 1,
    int limit = GameCollectionRemoteDataSource.maxPageSize,
    bool includeDeleted = false,
    bool deletedOnly = false,
    GameMedium? medium,
    bool? favorite,
    DateTime? updatedSince,
  }) async {
    final request = (
      page: page,
      limit: limit,
      includeDeleted: includeDeleted,
      updatedSince: updatedSince,
    );
    requests.add(request);
    return respond(request);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not in a hydrate');
}
