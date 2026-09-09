import 'package:models/domain.dart';

import 'paginated_result.dart';

/// One household from the list endpoint, with the members it embeds.
///
/// The two travel together because the server sends them together: the list
/// include carries each household's full member roster, and discarding it
/// would mean a second round trip for data already in hand. They stay
/// **separate values** rather than a members field on [Household] because the
/// repository caches them into separate tables through separate writers
/// (`cacheHousehold` / `cacheMembers`), and the return shape should match that
/// seam rather than the wire's nesting.
typedef HouseholdWithMembers = ({
  Household household,
  List<HouseholdMember> members,
});

/// Remote data source for household reads and writes against a BGE server.
///
/// The first domain REST client (P4, #39). Implementations run over a
/// **per-server** authenticated transport — the injected client carries
/// the base URL (path-prefix deployments included) and attaches the
/// session the endpoints require; this interface adds no auth handling
/// of its own.
///
/// ## Scope today: create + list
///
/// [createHousehold] (#39) and [fetchHouseholds] (#266). The remaining
/// household calls — update, delete, and every membership mutation — land
/// with the membership work (#122) and #246.
///
/// ## Failure classification
///
/// Every failure is wrapped as a [HouseholdRemoteException] — callers never
/// see a raw transport exception — split into:
///
/// - [HouseholdRemoteTransientException] (**retryable**): connection errors,
///   timeouts, 401 (a session can expire mid-flight), 408, 429, all 5xx, any
///   failure without a response status, and the three 4xx the rules below
///   carve out — every 404, every 407, and a 403 without the API's error
///   envelope. The caller should keep the queued create operation for a later
///   retry.
/// - [HouseholdRemotePermanentException]: 400 (validation), every 4xx the
///   three rules below do not carve out, and a 2xx whose body doesn't carry a
///   parseable household — retrying cannot succeed.
///
/// The governing question is not "did this fail" but **"will the same request
/// fail the same way again?"**, because that is what the drain acts on. So the
/// bar for permanent is evidence that the household API itself rejected the
/// request — not merely that something did. Three 4xx statuses do not clear
/// it:
///
/// **No 404 from any household route is permanent** (#297). Every household
/// route is fixed server-side, so a 404 reports a routing or deployment fault
/// — a misrouted path prefix, an API not yet deployed, a proxy answering for
/// it — rather than an answer about households. There is no household route
/// whose 404 could mean "this row is gone".
///
/// On [fetchHouseholds] the cost of getting this wrong is a hydrate that
/// ends for the life of the process, including after the server is fixed
/// (#266). On [createHousehold] it is worse, and is why the rule is not
/// per-route: once #121 owns cancel semantics, a permanent classification
/// cancels the queue entry and **discards the user's household** for a
/// failure a later retry would have survived.
///
/// **407 is never permanent** (#350). It is defined to come from a proxy, and
/// no household route emits one, so it says the request did not reach the
/// application. (511 needs no rule of its own — it is a 5xx.)
///
/// **403 is permanent only when the body carries the API's own error
/// envelope** (#350). Unlike 404, the envelope discriminates here: Nest
/// answers an unmatched route with a 404 carrying that envelope, but does not
/// answer one with a 403 — so an envelope-free 403 was written by a proxy or
/// WAF in front of the API, not by the application refusing the caller.
///
/// Implementations must not gate the **404** rule on the API's own error
/// envelope.
/// A 404 needs that envelope before it can be read as a statement about a
/// *row* (see [GameCollectionRemoteDataSource]), but no household route has
/// such a reading, and Nest answers an unmatched route with the same
/// envelope — so an envelope-gated rule would still call a partial deploy a
/// rejection. The membership mutations in #122 add the first household routes
/// whose 404 can carry row semantics — a member or household the request names
/// and the server says is gone — and that is when this contract grows a
/// per-route clause and the envelope requirement with it.
abstract class HouseholdRemoteDataSource {
  /// The server's `limit` ceiling for the household list. A larger `limit`
  /// is **rejected with a 400**, not clamped.
  static const int maxPageSize = 100;

  /// The server's depth ceiling: `(page - 1) * limit` may not exceed this,
  /// enforced as a validation error on `page`. Exceeding it is a 400, not an
  /// empty page. A household drain will never approach it.
  static const int maxPageDepth = 100000;

  /// Fetches **one page** of the households the acting user can read, newest
  /// first (`createdAt desc, id desc`), with the members each row embeds.
  ///
  /// Paging is the caller's: this returns the page the server gave and
  /// nothing more. Drain by following [PaginationMeta.hasMore] — never by
  /// inferring the end of the list from a page shorter than [limit].
  ///
  /// [page] is **1-based** and [limit] is capped at [maxPageSize]; both are
  /// validated server-side and a violation is a 400, so implementations throw
  /// [ArgumentError] before the request rather than spending a round trip on
  /// a rejection the caller could have known about locally.
  ///
  /// ### Scope is the caller's role, not their membership
  ///
  /// `GET /households` widens by role: a member gets the households they
  /// belong to, an admin gets **every household on the server**. This method
  /// reports what the server sent and makes no attempt to tell the two apart
  /// — `PaginationMeta.total` is the only available signal, and it is a hint
  /// rather than a determination. backend#364 is the membership-scoped read
  /// that would make the distinction real.
  ///
  /// Throws [HouseholdRemoteException] (see class doc for classification).
  Future<PaginatedResult<HouseholdWithMembers>> fetchHouseholds({
    int page = 1,
    int limit = maxPageSize,
  });

  /// Creates a household on the server.
  ///
  /// Wire contract (backend `libs/api/household`): `POST /api/households`
  /// `{ name, description?, image?, language?, visibility? }` → 201
  /// `{ message, household }`. The creator becomes `HouseholdOwner`
  /// server-side. [language] is an IETF BCP 47 tag; [visibility] is a
  /// `Private` | `Friends` enum name. The server assigns the id (the
  /// create DTO has no id field), so the returned [Household] carries the
  /// canonical id the caller reconciles onto its optimistic row.
  ///
  /// The returned [Household] has `isDirty` / `isLocalOnly` `false` — it is
  /// the server's confirmed state.
  ///
  /// Throws [HouseholdRemoteException] (see class doc for classification).
  Future<Household> createHousehold({
    required String name,
    String? description,
    String? image,
    String? language,
    String? visibility,
  });
}

/// Base class for all household remote-call failures.
sealed class HouseholdRemoteException implements Exception {
  const HouseholdRemoteException(this.message, {this.statusCode, this.cause});

  final String message;

  /// HTTP status when the failure carried a server response; null for
  /// connection-level faults.
  final int? statusCode;

  /// The underlying error (e.g. a `DioException`), when available.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// A retryable failure — the caller should keep the queued operation and
/// let it retry later. Covers connection errors, timeouts, 401/407/408/429,
/// 5xx, status-less failures, every 404, and a 403 that does not carry the
/// API's error envelope.
///
/// The 404, 407 and 403 rules each have a reason worth reading before
/// depending on them — see the classification section on
/// [HouseholdRemoteDataSource].
final class HouseholdRemoteTransientException extends HouseholdRemoteException {
  const HouseholdRemoteTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A non-retryable failure — retrying cannot succeed. Covers 400, a 403 that
/// carries the API's error envelope, every other 4xx the rules on
/// [HouseholdRemoteDataSource] do not carve out, plus a 2xx whose body has no
/// parseable household.
final class HouseholdRemotePermanentException extends HouseholdRemoteException {
  const HouseholdRemotePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
