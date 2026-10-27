import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [UserRemoteDataSource] whose answer the test scripts.
///
/// [searchUsers] records its call in [calls] and then runs [onSearchUsers].
/// An unscripted call throws [StateError], so a test can't pass by reaching a
/// route it never meant to.
class FakeUserRemote implements UserRemoteDataSource {
  final List<String> calls = [];

  Future<PaginatedResult<UserSummary>> Function(
    String query,
    int page,
    int limit,
  )?
  onSearchUsers;

  @override
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = UserRemoteDataSource.maxSearchPageSize,
  }) {
    calls.add('searchUsers($query)');
    final handler =
        onSearchUsers ?? (throw StateError('searchUsers was not scripted'));
    return handler(query, page, limit);
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

/// No usable answer from the API.
UserRemoteTransientException offline() =>
    const UserRemoteTransientException('offline');
