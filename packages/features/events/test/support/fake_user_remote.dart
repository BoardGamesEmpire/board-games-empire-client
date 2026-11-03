import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [UserRemoteDataSource] whose answer the test scripts, for the create
/// form's invitee search (#499). The user_search and household packages
/// keep their own: `bge_test_support`, where shared test code lives, does
/// not depend on `network_interface`, which this implements.
///
/// [searchUsers] records its call in [calls] and then runs [onSearchUsers].
/// An unscripted call throws [StateError], so a test can't pass by reaching a
/// route it never meant to.
class FakeUserRemote implements UserRemoteDataSource {
  final List<String> calls = [];

  Future<PaginatedResult<UserSummary>> Function(String query)? onSearchUsers;

  @override
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = UserRemoteDataSource.maxSearchPageSize,
  }) {
    calls.add('searchUsers($query)');
    final handler =
        onSearchUsers ?? (throw StateError('searchUsers was not scripted'));
    return handler(query);
  }

  Future<Map<ResourceType, ResourceAccess>> Function(
    Set<ResourceType> resourceTypes,
  )?
  onFetchAccess;

  @override
  Future<Map<ResourceType, ResourceAccess>> fetchAccess(
    Set<ResourceType> resourceTypes,
  ) {
    calls.add('fetchAccess');
    final handler =
        onFetchAccess ?? (throw StateError('fetchAccess was not scripted'));
    return handler(resourceTypes);
  }
}

/// One page holding [items].
PaginatedResult<T> pageOf<T>(List<T> items) => PaginatedResult(
  items: items,
  meta: PaginationMeta(
    page: 1,
    limit: UserRemoteDataSource.maxSearchPageSize,
    total: items.length,
    totalPages: 1,
    hasMore: false,
  ),
);
