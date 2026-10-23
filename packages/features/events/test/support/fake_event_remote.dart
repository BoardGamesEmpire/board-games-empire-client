import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// What the hydrate asked for in one list request.
typedef EventListRequest = ({int page, int limit});

/// An event remote that answers list requests from [respond] and records
/// each one. The list read is the only call a hydrate makes; anything else
/// throws.
class FakeEventRemote implements EventRemoteDataSource {
  FakeEventRemote(this.respond);

  /// Serves scripted [pages], page N from `pages[N - 1]`, and throws [error]
  /// for [failOnPage] instead.
  FakeEventRemote.pages(
    List<PaginatedResult<EventSnapshot>> pages, {
    int? failOnPage,
    Object error = const EventRemoteTransientException('offline'),
  }) : respond = ((request) {
         if (request.page == failOnPage) throw error;
         return pages[request.page - 1];
       });

  final FutureOr<PaginatedResult<EventSnapshot>> Function(
    EventListRequest request,
  )
  respond;

  final List<EventListRequest> requests = [];

  @override
  Future<PaginatedResult<EventSnapshot>> fetchEvents({
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
  }) async {
    final request = (page: page, limit: limit);
    requests.add(request);
    return respond(request);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not in a hydrate');
}
