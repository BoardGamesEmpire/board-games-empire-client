import 'package:models/domain.dart';

/// Remote data source for household write operations against a BGE server.
///
/// The first domain REST client (P4, #39). Implementations run over a
/// **per-server** authenticated transport — the injected client carries
/// the base URL (path-prefix deployments included) and attaches the
/// session the endpoints require; this interface adds no auth handling
/// of its own.
///
/// ## Scope today: create only
///
/// Only [createHousehold] is defined. The create flow needs nothing more:
/// the server assigns the household id, which the caller reconciles onto
/// the optimistic local row, and the creator's `HouseholdOwner` member row
/// is synthesized client-side (its server counterpart is not read in the
/// create-only alpha, so no member fetch is required). A `fetchHouseholds`
/// method — including the members the list endpoint embeds — will land with
/// the initial household-list sync / membership work (#122), tested against
/// the real member response shape at that point.
///
/// ## Failure classification
///
/// Every failure is wrapped as a [HouseholdRemoteException] — callers never
/// see a raw transport exception — split into:
///
/// - [HouseholdRemoteTransientException] (**retryable**): connection errors,
///   timeouts, 401 (a session can expire mid-flight), 408, 429, all 5xx, and
///   any failure without a response status. The caller should keep the
///   queued create operation for a later retry.
/// - [HouseholdRemotePermanentException]: 400 (validation), 403 (forbidden),
///   every other 4xx, and a 2xx whose body doesn't carry a parseable
///   household — retrying cannot succeed.
abstract class HouseholdRemoteDataSource {
  /// Creates a household on the server.
  ///
  /// Wire contract (backend `libs/api/household`): `POST /households`
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
/// let it retry later. Covers connection errors, timeouts, 401/408/429,
/// 5xx, and status-less failures.
final class HouseholdRemoteTransientException extends HouseholdRemoteException {
  const HouseholdRemoteTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A non-retryable failure — retrying cannot succeed. Covers 400/403 and
/// every other 4xx, plus a 2xx whose body has no parseable household.
final class HouseholdRemotePermanentException extends HouseholdRemoteException {
  const HouseholdRemotePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
