import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// What the hydrate asked for in one list request.
typedef EventListRequest = ({int page, int limit});

/// An event remote that answers list requests from [respond] and detail
/// requests from [detail], and records each one. A read it has no answer
/// for throws, as does anything else.
class FakeEventRemote implements EventRemoteDataSource {
  FakeEventRemote(
    FutureOr<PaginatedResult<EventSnapshot>> Function(EventListRequest request)
    this.respond,
  ) : detail = null;

  /// Serves scripted [pages], page N from `pages[N - 1]`, and throws [error]
  /// for [failOnPage] instead.
  FakeEventRemote.pages(
    List<PaginatedResult<EventSnapshot>> pages, {
    int? failOnPage,
    Object error = const EventRemoteTransientException('offline'),
  }) : respond = ((request) {
         if (request.page == failOnPage) throw error;
         return pages[request.page - 1];
       }),
       detail = null;

  /// Answers detail reads from [detail], for the detail screen (#498),
  /// which makes no list read.
  FakeEventRemote.detail(
    FutureOr<EventSnapshot> Function(String id) this.detail,
  ) : respond = null;

  final FutureOr<PaginatedResult<EventSnapshot>> Function(
    EventListRequest request,
  )?
  respond;

  final FutureOr<EventSnapshot> Function(String id)? detail;

  final List<EventListRequest> requests = [];

  /// The id of each detail read, in order.
  final List<String> detailRequests = [];

  @override
  Future<PaginatedResult<EventSnapshot>> fetchEvents({
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
  }) async {
    final respond = this.respond;
    if (respond == null) {
      throw UnimplementedError('fetchEvents is not in a detail read');
    }
    final request = (page: page, limit: limit);
    requests.add(request);
    return respond(request);
  }

  @override
  Future<EventSnapshot> fetchEvent(String id) async {
    final detail = this.detail;
    if (detail == null) {
      throw UnimplementedError('fetchEvent is not in a hydrate');
    }
    detailRequests.add(id);
    return detail(id);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}
