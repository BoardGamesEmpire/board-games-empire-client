import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [HouseholdInviteRemoteDataSource] whose every answer the test scripts.
///
/// Each method records its call in [calls] and then runs the matching
/// handler. An unscripted call throws [StateError], so a test can't pass by
/// reaching a route it never meant to.
class FakeHouseholdInviteRemote implements HouseholdInviteRemoteDataSource {
  final List<String> calls = [];

  /// The drafts [send] was given, in order.
  final List<HouseholdInviteDraft> sentDrafts = [];

  Future<HouseholdInvite> Function(
    String householdId,
    HouseholdInviteDraft draft,
  )?
  onSend;
  Future<PaginatedResult<HouseholdInvite>> Function(
    String householdId,
    HouseholdInviteStatus? status,
    int page,
    int limit,
  )?
  onFetchHouseholdInvites;
  Future<PaginatedResult<HouseholdInvite>> Function(int page, int limit)?
  onFetchInbox;
  Future<AcceptedHouseholdInvite> Function(String inviteId)? onAccept;
  Future<HouseholdInvite> Function(String inviteId)? onDecline;
  Future<HouseholdInvite> Function(String inviteId)? onWithdraw;
  Future<HouseholdInvite> Function(String householdId, String inviteId)?
  onRevoke;
  Future<HouseholdInvite> Function(String householdId, String inviteId)?
  onApprove;
  Future<PaginatedResult<UserSummary>> Function(
    String query,
    int page,
    int limit,
  )?
  onSearchUsers;

  /// Answers every household list read with [rows] on one page.
  void listing(List<HouseholdInvite> rows) =>
      onFetchHouseholdInvites = (_, _, _, _) async => pageOf(rows);

  @override
  Future<HouseholdInvite> send(String householdId, HouseholdInviteDraft draft) {
    calls.add('send($householdId)');
    sentDrafts.add(draft);
    return _run(onSend, 'send')(householdId, draft);
  }

  @override
  Future<PaginatedResult<HouseholdInvite>> fetchHouseholdInvites(
    String householdId, {
    HouseholdInviteStatus? status,
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.defaultPageSize,
  }) {
    calls.add(
      'fetchHouseholdInvites($householdId, ${status?.name}, $page, $limit)',
    );
    return _run(onFetchHouseholdInvites, 'fetchHouseholdInvites')(
      householdId,
      status,
      page,
      limit,
    );
  }

  @override
  Future<PaginatedResult<HouseholdInvite>> fetchInbox({
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.defaultPageSize,
  }) {
    calls.add('fetchInbox($page, $limit)');
    return _run(onFetchInbox, 'fetchInbox')(page, limit);
  }

  @override
  Future<AcceptedHouseholdInvite> accept(String inviteId) {
    calls.add('accept($inviteId)');
    return _run(onAccept, 'accept')(inviteId);
  }

  @override
  Future<HouseholdInvite> decline(String inviteId) {
    calls.add('decline($inviteId)');
    return _run(onDecline, 'decline')(inviteId);
  }

  @override
  Future<HouseholdInvite> withdraw(String inviteId) {
    calls.add('withdraw($inviteId)');
    return _run(onWithdraw, 'withdraw')(inviteId);
  }

  @override
  Future<HouseholdInvite> revoke(String householdId, String inviteId) {
    calls.add('revoke($householdId, $inviteId)');
    return _run(onRevoke, 'revoke')(householdId, inviteId);
  }

  @override
  Future<HouseholdInvite> approve(String householdId, String inviteId) {
    calls.add('approve($householdId, $inviteId)');
    return _run(onApprove, 'approve')(householdId, inviteId);
  }

  @override
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.maxSearchPageSize,
  }) {
    calls.add('searchUsers($query)');
    return _run(onSearchUsers, 'searchUsers')(query, page, limit);
  }

  static T _run<T extends Function>(T? handler, String name) =>
      handler ?? (throw StateError('$name was not scripted'));
}

/// One page holding [items].
PaginatedResult<T> pageOf<T>(
  List<T> items, {
  int page = 1,
  int limit = HouseholdInviteRemoteDataSource.defaultPageSize,
  int? total,
  bool hasMore = false,
}) => PaginatedResult(
  items: items,
  meta: PaginationMeta(
    page: page,
    limit: limit,
    total: total ?? items.length,
    totalPages: 1,
    hasMore: hasMore,
  ),
);

/// The API's refusal with [status].
HouseholdInviteRefusedException refused(int status, {InviteQuota? quota}) =>
    HouseholdInviteRefusedException(
      'refused',
      statusCode: status,
      quota: quota,
    );

/// No usable answer from the API.
HouseholdInviteTransientException offline() =>
    const HouseholdInviteTransientException('offline');

/// An invite for tests. [inviterId] defaults to someone other than the
/// viewer the tests use, `u_me`.
HouseholdInvite invite(
  String id, {
  HouseholdInviteStatus status = HouseholdInviteStatus.pending,
  String inviterId = 'u_other',
  HouseholdRole? role = HouseholdRole.householdMember,
  String? inviteeName,
  String? inviteeEmail,
  String? householdId,
  String? householdName,
}) => HouseholdInvite(
  id: id,
  status: status,
  inviter: UserSummary(id: inviterId, username: inviterId),
  role: role,
  inviteeName: inviteeName ?? 'Invitee $id',
  inviteeEmail: inviteeEmail,
  householdId: householdId,
  householdName: householdName,
  // Midday, so the date reads the same in every test machine's zone.
  expiresAt: DateTime.utc(2026, 10, 26, 12),
  createdAt: DateTime.utc(2026, 10, 19),
);
