import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// The arguments one [AdminHouseholdRemoteDataSource.fetchPage] call sent.
typedef AdminHouseholdPageRequest = ({
  AdminHouseholdStatus status,
  String? query,
  AdminHouseholdSort sort,
  int page,
  int limit,
});

/// An [AdminHouseholdRemoteDataSource] whose every answer the test scripts.
///
/// Each method records its call, with its arguments, in [calls] and then runs
/// the matching handler. An unscripted call throws [StateError], so a test
/// can't pass by reaching a route it never meant to.
class FakeAdminHouseholdRemote implements AdminHouseholdRemoteDataSource {
  final List<String> calls = [];

  Future<PaginatedResult<AdminHouseholdRow>> Function(
    AdminHouseholdPageRequest request,
  )?
  onFetchPage;
  Future<AdminHouseholdDetail> Function(String id)? onFetchDetail;
  Future<void> Function(String id)? onRestore;

  /// Answers every list read with [rows] on one page.
  void listing(List<AdminHouseholdRow> rows, {bool hasMore = false}) =>
      onFetchPage = (request) async =>
          adminPageOf(rows, page: request.page, hasMore: hasMore);

  @override
  Future<PaginatedResult<AdminHouseholdRow>> fetchPage({
    AdminHouseholdStatus status = AdminHouseholdStatus.live,
    String? query,
    AdminHouseholdSort sort = AdminHouseholdSort.name,
    int page = 1,
    int limit = AdminHouseholdRemoteDataSource.pageSize,
  }) {
    calls.add(
      describeFetchPage(
        status: status,
        query: query,
        sort: sort,
        page: page,
        limit: limit,
      ),
    );
    return _run(onFetchPage, 'fetchPage')((
      status: status,
      query: query,
      sort: sort,
      page: page,
      limit: limit,
    ));
  }

  @override
  Future<AdminHouseholdDetail> fetchDetail(String id) {
    calls.add('fetchDetail($id)');
    return _run(onFetchDetail, 'fetchDetail')(id);
  }

  @override
  Future<void> restore(String id) {
    calls.add('restore($id)');
    return _run(onRestore, 'restore')(id);
  }

  static T _run<T extends Function>(T? handler, String name) =>
      handler ?? (throw StateError('$name was not scripted'));
}

/// How [FakeAdminHouseholdRemote.calls] records a `fetchPage` call. The
/// defaults are the list's first read.
String describeFetchPage({
  AdminHouseholdStatus status = AdminHouseholdStatus.live,
  String? query,
  AdminHouseholdSort sort = AdminHouseholdSort.name,
  int page = 1,
  int limit = AdminHouseholdRemoteDataSource.pageSize,
}) =>
    'fetchPage(${status.wireName}, ${sort.wireName}, q: $query, '
    'page: $page, limit: $limit)';

/// A row whose name says which one it is, unless a test names it. Deleted
/// when [deleted] is true.
AdminHouseholdRow adminRow(
  String id, {
  String? name,
  bool deleted = false,
  int memberCount = 2,
  List<AdminHouseholdOwner> owners = const [],
}) => AdminHouseholdRow(
  id: id,
  name: name ?? 'Household $id',
  reach: Reach.private,
  createdAt: DateTime.utc(2026),
  deletedAt: deleted ? DateTime.utc(2026, 10, 2) : null,
  memberCount: memberCount,
  owners: owners,
);

/// One page of the staff list, as the remote hands it over.
PaginatedResult<AdminHouseholdRow> adminPageOf(
  List<AdminHouseholdRow> rows, {
  int page = 1,
  bool hasMore = false,
}) => PaginatedResult(
  items: rows,
  meta: PaginationMeta(
    page: page,
    limit: AdminHouseholdRemoteDataSource.pageSize,
    total: rows.length,
    totalPages: hasMore ? page + 1 : page,
    hasMore: hasMore,
  ),
);

/// A member of a household's roster, named [name] unless it has none.
HouseholdMember adminMember(
  String id, {
  String? name,
  HouseholdRole? role = HouseholdRole.householdMember,
}) => HouseholdMember(
  id: id,
  userId: 'u_$id',
  householdId: 'h_1',
  role: role,
  username: name?.toLowerCase(),
  displayName: name,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// A household as the staff detail reads it. Every fact is present unless a
/// test drops it.
AdminHouseholdDetail adminDetail({
  String id = 'h_1',
  String name = "Ada's table",
  String? description = 'Friday board games',
  Reach reach = Reach.friends,
  String? languageName = 'English',
  List<HouseholdMember>? members,
}) => AdminHouseholdDetail(
  id: id,
  name: name,
  description: description,
  reach: reach,
  languageName: languageName,
  createdAt: DateTime.utc(2026, 3, 14, 12),
  members:
      members ??
      [
        adminMember('m1', name: 'Ada', role: HouseholdRole.householdOwner),
        adminMember('m2', name: 'Bea'),
      ],
);
