import 'package:models/domain.dart';

/// Remote data source for the current user's [GameCollection] entries (#253).
///
/// The network seam the collection slice had none of: #44's initial hydrate
/// reads through [fetchCollectionPage], and the sync-queue drain worker (#121)
/// pushes queued collection operations through [addToCollection],
/// [updateEntry] and [removeEntry]. Responses are reconciled into the local
/// cache by `GameCollectionRepository.reconcileFromServer`.
///
/// Implementations run over a **per-server** authenticated transport — the
/// injected client carries the base URL (path-prefix deployments included) and
/// attaches the session the endpoints require; this interface adds no auth
/// handling of its own. Same shape as [HouseholdRemoteDataSource].
///
/// ## Wire contract
///
/// Backend `libs/api/game-collection`, all under the `api` global prefix:
///
/// | Method | Path | Success | Envelope |
/// |---|---|---|---|
/// | [fetchCollectionPage] | `GET /api/game-collections` | 200 | `{ collections: [...] }` |
/// | [fetchEntry] | `GET /api/game-collections/:id` | 200 | `{ collection }` |
/// | [addToCollection] | `POST /api/game-collections` | 201 | `{ collection, message }` |
/// | [updateEntry] | `PATCH /api/game-collections/:id` | 200 | `{ collection, message }` |
/// | [removeEntry] | `DELETE /api/game-collections/:id` | 200 | `{ collection, message }` |
///
/// Every returned [GameCollection] is server-confirmed state: `isDirty` and
/// `isLocalOnly` are `false`.
///
/// ## What the mapping drops (#253 D5)
///
/// The server response carries three things the domain model has no field for:
/// `visibility`, `deleteReason`, and an embedded `platformGame` / `release`
/// summary (game title, subtitle, image, thumbnail; platform name and slug).
/// The summary is exactly what a collection list needs to render, and dropping
/// it is a known cost tracked by **#259** — capturing it is a storage decision,
/// not a transport one, so it does not happen here.
///
/// ## What the request bodies deliberately cannot carry
///
/// `playCount` and `lastPlayed` are **server-managed** (backend: "server-managed
/// via play tracking"), and the API runs `whitelist: true,
/// forbidNonWhitelisted: true` — a body containing either is a **400**. They are
/// therefore absent from [updateEntry]'s parameters rather than accepted and
/// silently discarded: the transport cannot construct a request the server is
/// guaranteed to reject. `UpdateCollectionOperation` still carries both, so the
/// caller drops them at the call site; the domain-level fix is **#258** (#253 D3).
///
/// Likewise absent: `platformGameId` and `medium` on [updateEntry] — they are
/// the row's identity server-side, and changing a game's medium means adding a
/// second entry.
///
/// ## Null means "leave unchanged", never "clear" (#253 D4)
///
/// The backend PATCH follows standard REST semantics: an omitted field is
/// preserved, an explicit `null` **clears** it. The client's own contract is the
/// opposite — `null` means leave-unchanged (see `TODO(clear-fields)` on
/// [GameCollectionRepository.updateCollectionEntry]).
///
/// Implementations MUST therefore **omit** null parameters from the request body
/// rather than serialize them. No method on this interface can express a
/// deliberate clear; that needs the `clearFields` operation the repository's
/// TODO describes.
///
/// ## Failure classification
///
/// Every **transport** failure is wrapped as a [GameCollectionRemoteException]
/// — callers never see a raw `DioException`. Four variants, mirroring
/// [HouseholdRemoteException]'s transient/permanent split plus the 404 contexts
/// this API has (#253 D6):
///
/// - [GameCollectionRemoteTransientException] (**retryable**): connection
///   errors, timeouts, 401 (a session can expire mid-flight), 408, 429, all
///   5xx, and any failure without a response status.
/// - [GameCollectionRemotePermanentException]: 400 (validation), 403, every
///   other 4xx, and a 2xx whose body carries no parseable entry.
/// - [GameCollectionNotFoundException]: a 404 from [fetchEntry], [updateEntry]
///   or [addToCollection] — the row (or, for an add, the platform game or
///   release) does not exist for this actor. Permanent.
/// - [GameCollectionAlreadyRemovedException]: a 404 from [removeEntry] that
///   carries the API's error envelope (see below). **Not a failure to retry.**
///   The backend's delete filter includes `deletedAt: null`, so a re-sent
///   removal 404s from a server that has already done exactly what was asked;
///   a drain should mark the operation completed.
///
/// A 404 from [fetchCollectionPage] is none of those — it is **transient**. An
/// authenticated user's collection is never absent (an empty one is a 200 with
/// an empty array), so a 404 on the list route means the request never reached
/// the endpoint: an unserved path prefix, an undeployed API, a proxy
/// misconfiguration. All are fixed server-side, so a hydrate should retry
/// rather than give up permanently.
///
/// ### A row-level 404 requires evidence the application answered
///
/// Both row-level readings above are conclusions about a **row**, and a 404
/// alone does not license either: a proxy, gateway or load balancer answers
/// 404 too, and then the status says only that the request did not arrive.
///
/// So implementations MUST require the API's own error envelope —
/// `{ statusCode, message, error }`, which the backend's global
/// `I18nExceptionFilter` renders for every application `HttpException` —
/// before returning [GameCollectionAlreadyRemovedException] or
/// [GameCollectionNotFoundException]. A 404 without it is **transient**.
///
/// That means the envelope **whole**, not a prefix of it, and with its
/// `statusCode` agreeing with the response's own status. The filter builds the
/// body from the exception's status, so a real application 404 always carries
/// all three fields and always says `404`; a two-field lookalike, or a body
/// announcing some other status, came from a different producer — a gateway
/// rewriting an upstream failure — and licenses no row-level conclusion.
///
/// This matters most for a removal, because already-removed tells a drain to
/// mark the operation **completed**: doing that for a request the service
/// never saw silently discards the user's deletion, and the entry reappears on
/// the next hydrate. A patch is the same hazard one step removed — missing-row
/// is permanent, so a proxy 404 would discard the user's edit.
///
/// Known residual: if the collection module itself is not deployed, Nest's own
/// route-not-found *is* that envelope. Telling it apart would mean matching
/// message text, which is translated per request locale. The mitigating
/// property is that the list route 404s in the same deployment and is transient
/// unconditionally, so a missing module shows up as a hydrate that never
/// succeeds.
///
/// ### Argument violations are not part of that taxonomy
///
/// A call that cannot produce a valid request throws [ArgumentError],
/// unwrapped — an out-of-range page, a non-positive quantity, an empty patch.
/// These are caller bugs, not server answers, and a drain that catches
/// [GameCollectionRemoteException] will not catch them.
///
/// One of them is reachable from real queued data rather than from a coding
/// slip, and callers must handle it before calling: an
/// `UpdateCollectionOperation` whose only populated fields are `playCount`
/// and/or `lastPlayed` has **nothing this transport can send** once those are
/// dropped, so [updateEntry] would be called with every field null and throw.
/// Such an operation is a no-op against this API — complete it without calling
/// here. It exists only because the repository's update surface accepts fields
/// the server owns; that is what #258 fixes.
abstract class GameCollectionRemoteDataSource {
  /// The backend's `limit` ceiling for this endpoint
  /// (`GAME_COLLECTION_MAX_PAGE_SIZE`). A larger `limit` is rejected with a
  /// 400, not clamped.
  static const int maxPageSize = 100;

  /// The backend's `offset` ceiling (`DEFAULT_MAX_OFFSET`) — a hardening bound
  /// on scan-and-discard paging, not a real deep-pagination story. A larger
  /// offset is rejected with a 400.
  static const int maxOffset = 100000;

  /// Fetches **one page** of the acting user's collection, newest-updated
  /// first.
  ///
  /// Paging is the caller's (#253 D2): this returns the page the server gave
  /// and nothing more.
  ///
  /// ### End of list
  ///
  /// The response envelope carries **no total and no `hasMore`** (tracked
  /// upstream as backend#230), so the only available signal is the page
  /// length: **a page shorter than [limit] is the last page.** Terminating on
  /// an empty page instead is correct but costs one extra round trip on every
  /// hydrate, and terminating on anything else is wrong.
  ///
  /// [offset] must be in `0..maxOffset` and [limit] in `1..maxPageSize`;
  /// both are validated server-side and a violation is a 400, so
  /// implementations throw [ArgumentError] before the request instead.
  ///
  /// ### Tombstones
  ///
  /// A default page **excludes** tombstoned entries, so a hydrate that leaves
  /// [includeDeleted] false never learns about server-side removals. Pass
  /// [includeDeleted] for a full picture, or [deletedOnly] for tombstones
  /// alone. [updatedSince] combined with [includeDeleted] is the delta-sync
  /// shape.
  Future<List<GameCollection>> fetchCollectionPage({
    int offset = 0,
    int limit = maxPageSize,
    bool includeDeleted = false,
    bool deletedOnly = false,
    GameMedium? medium,
    bool? favorite,
    DateTime? updatedSince,
  });

  /// Fetches a single entry by its server id.
  ///
  /// Throws [GameCollectionNotFoundException] if the row does not exist for
  /// this actor (missing, another user's, or outside the actor's read scope —
  /// the server collapses all three into a 404).
  Future<GameCollection> fetchEntry(String id);

  /// Adds a game to the acting user's collection.
  ///
  /// The endpoint is an **idempotent upsert** on
  /// `(userId, platformGameId, medium)`: re-adding a live entry updates the
  /// supplied fields, and re-adding a tombstoned one resurrects it with
  /// `playCount` / `lastPlayed` intact. A re-sent add therefore cannot create
  /// a duplicate row — which is why no idempotency key is needed here, unlike
  /// household create (see the correction on #121).
  ///
  /// [quantity] is an **absolute** value, not an increment; the server
  /// overwrites. Callers draining an `AddToCollectionOperation` pass its
  /// final post-write quantity, which is what that operation records.
  ///
  /// The server assigns the id — the create DTO has no id field — so the
  /// returned entry carries the canonical id the caller reconciles onto its
  /// optimistic row (via the triplet lookup and
  /// `SyncQueueRepository.remapCollectionId`).
  ///
  /// A missing platform game or release is a 404 mapped to
  /// [GameCollectionNotFoundException]; a release that belongs to a different
  /// platform game is a 400.
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    String? releaseId,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
  });

  /// Patches the mutable fields of an entry.
  ///
  /// Null parameters are omitted from the body, not sent as `null` — see the
  /// null-handling section on this class. At least one field must be non-null:
  /// the server rejects an empty patch with a 400, so implementations throw
  /// [ArgumentError] before the request instead.
  ///
  /// A caller draining an `UpdateCollectionOperation` whose only populated
  /// fields are the server-managed ones has nothing to send and must not call
  /// this method — see "Argument violations" on this class.
  ///
  /// Throws [GameCollectionNotFoundException] on a 404.
  Future<GameCollection> updateEntry({
    required String id,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
    String? releaseId,
  });

  /// Removes an entry — a **soft delete**. The server tombstones the row so
  /// play history survives a later re-add, and returns the tombstoned entry
  /// with `deletedAt` set, which is exactly the shape
  /// `reconcileFromServer` treats as a removal confirmation.
  ///
  /// [reason] is an optional `GameRemovalReason` enum name (`Destroyed`,
  /// `Gifted`, `Lost`, `Other`, `Sold`, `Stolen`, `Traded`). The domain model
  /// has no field for it, so it round-trips nowhere today; it is carried
  /// because the endpoint accepts it and a confirm-on-remove UX (#46) may want
  /// to ask.
  ///
  /// Throws [GameCollectionAlreadyRemovedException] on a 404 **that came from
  /// the application** — the row is already tombstoned (or unreachable to this
  /// actor), which for a re-sent removal means the work is done. Callers should
  /// treat it as completion, not failure. A 404 without the API's error
  /// envelope is transient instead; see "A row-level 404 requires evidence"
  /// on this class.
  Future<GameCollection> removeEntry(String id, {String? reason});
}

/// Base class for all collection remote-call failures.
sealed class GameCollectionRemoteException implements Exception {
  const GameCollectionRemoteException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;

  /// HTTP status when the failure carried a server response; null for
  /// connection-level faults.
  final int? statusCode;

  /// The underlying error (e.g. a `DioException`), when available.
  final Object? cause;

  /// Whether re-sending the same request could succeed later.
  ///
  /// False for [GameCollectionAlreadyRemovedException] too, but for the
  /// opposite reason: there is nothing left to do, not nothing that can be
  /// done. Do not use this getter alone to decide an operation's fate — a
  /// drain should `switch` on the variant.
  bool get isRetryable => false;

  @override
  String toString() =>
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// A retryable failure — the caller should keep the queued operation and let
/// it retry later. Covers connection errors, timeouts, 401/408/429, 5xx, and
/// status-less failures.
final class GameCollectionRemoteTransientException
    extends GameCollectionRemoteException {
  const GameCollectionRemoteTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });

  @override
  bool get isRetryable => true;
}

/// A non-retryable failure — retrying cannot succeed. Covers 400/403 and every
/// other 4xx that is not a 404, plus a 2xx whose body has no parseable entry.
final class GameCollectionRemotePermanentException
    extends GameCollectionRemoteException {
  const GameCollectionRemotePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A 404 on a read or a patch: the row does not exist for this actor.
///
/// Permanent. The server collapses missing, foreign and out-of-scope rows into
/// one 404, so this carries no information about which.
final class GameCollectionNotFoundException
    extends GameCollectionRemoteException {
  const GameCollectionNotFoundException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A 404 on a removal: the entry is already tombstoned (or unreachable).
///
/// **Not a failure to retry, and not a failure to report.** The backend's
/// delete filter includes `deletedAt: null`, so a re-sent
/// `RemoveFromCollectionOperation` 404s from a server that has already applied
/// the removal. A drain should mark the operation completed; treating it as a
/// permanent failure would discard a successful sync, and treating it as
/// transient would retry it forever.
final class GameCollectionAlreadyRemovedException
    extends GameCollectionRemoteException {
  const GameCollectionAlreadyRemovedException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
