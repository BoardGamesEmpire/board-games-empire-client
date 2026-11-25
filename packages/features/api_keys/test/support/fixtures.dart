import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

class MockApiKeyRemoteDataSource extends Mock
    implements ApiKeyRemoteDataSource {}

/// A key as the server answers one, with the fields a test names.
ApiKey apiKey(
  String id, {
  String? name = 'CI deploy',
  String? start = 'bge_a1B2',
  List<ApiKeyScope> scopes = const [ApiKeyScope(slug: 'collection:read')],
  bool enabled = true,
  DateTime? expiresAt,
  DateTime? lastUsedAt,
}) => ApiKey(
  id: id,
  name: name,
  start: start,
  scopes: scopes,
  enabled: enabled,
  createdAt: DateTime.utc(2026, 11),
  expiresAt: expiresAt,
  lastUsedAt: lastUsedAt,
);

/// One page of [items], saying [hasMore] or not.
PaginatedResult<ApiKey> pageOf(
  List<ApiKey> items, {
  int page = 1,
  bool hasMore = false,
}) => PaginatedResult(
  items: items,
  meta: PaginationMeta(
    page: page,
    limit: ApiKeyRemoteDataSource.defaultPageSize,
    total: items.length + (hasMore ? 1 : 0),
    totalPages: hasMore ? page + 1 : page,
    hasMore: hasMore,
  ),
);

/// A permission the caller may grant, at [riskLevel].
GrantablePermission permission(
  String slug, {
  RiskLevel riskLevel = RiskLevel.low,
  String? description,
  bool pinnable = false,
}) => GrantablePermission(
  slug: slug,
  description: description ?? 'Do $slug',
  riskLevel: riskLevel,
  pinnable: pinnable,
);

/// Answers [MockApiKeyRemoteDataSource.fetchGrantable] with [permissions].
void answerGrantable(
  MockApiKeyRemoteDataSource remote, [
  List<GrantablePermission> permissions = const [],
]) => when(remote.fetchGrantable).thenAnswer((_) async => permissions);

/// Answers page [page] with [keys]. The list always names the page it asks
/// for.
void answerPage(
  MockApiKeyRemoteDataSource remote,
  List<ApiKey> keys, {
  int page = 1,
  bool hasMore = false,
}) => when(
  () => remote.fetchPage(
    page: page,
    limit: any(named: 'limit'),
  ),
).thenAnswer((_) async => pageOf(keys, page: page, hasMore: hasMore));
