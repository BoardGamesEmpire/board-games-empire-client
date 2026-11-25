import 'package:meta/meta.dart';
import 'package:models/domain.dart';
import 'package:network_interface/src/paginated_result.dart';

/// Remote data source for the signed-in user's API keys (#1028).
///
/// There is no local copy: a screen reads through this each time it opens.
///
/// Implementations run over a **per-server** authenticated transport, like
/// [SystemSettingsRemoteDataSource]: the injected client carries the base URL
/// and the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/api-key`, all under the `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchGrantable] | `GET /api/api-keys/grantable` | `{ permissions: [{ slug, description, riskLevel, pinnable }] }`, not paged |
/// | [fetchPage] | `GET /api/api-keys?page=&limit=` | `{ apiKeys: [...], pagination: {...} }` |
/// | [fetch] | `GET /api/api-keys/:id` | `{ apiKey }` |
/// | [create] | `POST /api/api-keys` | `{ name, scopes \| preset, expiresInDays?, confirmCritical? }`; `{ message, apiKey, secret }` |
/// | [update] | `PATCH /api/api-keys/:id` | the changed fields; `{ message, apiKey }` |
/// | [delete] | `DELETE /api/api-keys/:id` | `{ message }` |
///
/// A key is `{ id, name?, start?, scopes: [{ slug, resourceId? }], expiresAt?,
/// enabled, lastUsedAt?, createdAt }`, and `riskLevel` is one of `Low`,
/// `Medium`, `High` or `Critical`.
///
/// A scope with no pin leaves `resourceId` out of the JSON. The server refuses
/// both `null` and an empty string there.
///
/// The secret is in the answer to [create] and nowhere else. It is kept in
/// memory: never stored, logged, or put in an exception or its message.
///
/// The coded failures below arrive in the API's error envelope
/// `{ statusCode, error, message, code, ...fields }`, with the fields at the
/// top level. A coded body without the envelope is not the API's, and gets no
/// coded failure.
///
/// ## Failures
///
/// - [ApiKeyNeedsRecentSignInException]: 403 with code
///   `API_KEY_NEEDS_RECENT_SIGN_IN`. The session is too old to make or change
///   a key.
/// - [ApiKeySessionRequiredException]: 403 with code
///   `API_KEY_SESSION_REQUIRED`. The call came from an API key, not a signed-in
///   session.
/// - [ApiKeyNotFoundException]: 404 with code `API_KEY_NOT_FOUND`.
/// - [ApiKeyCriticalNeedsConfirmationException]: 422 with code
///   `API_KEY_CRITICAL_NEEDS_CONFIRMATION`. The request holds a Critical
///   permission and carried no `confirmCritical`.
/// - [ApiKeyScopeNotGrantableException]: 422 with code
///   `API_KEY_SCOPE_NOT_GRANTABLE`, naming the `slug`.
/// - [ApiKeyScopeNotPinnableException]: 422 with code
///   `API_KEY_SCOPE_NOT_PINNABLE`, naming the `slug`.
/// - [ApiKeyExpiryOutOfRangeException]: 422 with code
///   `API_KEY_EXPIRY_OUT_OF_RANGE`, with the `min` and `max` in days.
/// - [ApiKeyPermanentException]: a 400 validation error, any other enveloped
///   4xx, and a 2xx whose body cannot be read as the contract above. A 422 with
///   code `API_KEY_SCOPES_OR_PRESET` is one too: [ApiKeyCreate] holds exactly
///   one grant, so the request types make it unreachable.
/// - [ApiKeyTransientException]: anything else, by the shared rules.
///
/// Every failure carries [ApiKeyRemoteException.apiMessage], the `message` of
/// the API's error envelope. An implementation fills it from the envelope when
/// the refusal came from the API, and leaves it null otherwise.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped, before any request: a page below 1, a limit outside
/// `1..maxPageSize`, a name that is empty once trimmed or longer than
/// [maxNameLength], an expiry outside `minExpiryDays..maxExpiryDays`, or an
/// empty [ApiKeyPatch]. A scope with an empty slug or an empty resourceId
/// throws too: an unpinned scope's resourceId is null, never empty. So does a
/// NUL character in a name, a slug or a resourceId, which the server refuses.
/// [ApiKeyCreate] and [ApiKeyPatch] are not validated in their constructors,
/// so the implementation checks them.
abstract class ApiKeyRemoteDataSource {
  /// The page size the screens ask for, and the server's default.
  static const int defaultPageSize = 20;

  /// The server's `limit` ceiling for the list.
  static const int maxPageSize = 50;

  /// The fewest days a key may last.
  static const int minExpiryDays = 1;

  /// The most days a key may last.
  static const int maxExpiryDays = 365;

  /// What the server uses for a key's lifetime when none is sent.
  static const int defaultExpiryDays = 90;

  /// The longest name a key may have, once trimmed, counted in Dart
  /// `String.length` (UTF-16 units). That is stricter than the server's own
  /// count by `serverStringLength`, and matches the sign-in library's check, so
  /// a name that passes here passes both.
  static const int maxNameLength = 32;

  /// Every permission the caller may give a key. Not paged.
  Future<List<GrantablePermission>> fetchGrantable();

  /// One page of the caller's keys.
  Future<PaginatedResult<ApiKey>> fetchPage({
    int page = 1,
    int limit = defaultPageSize,
  });

  /// The key [id].
  ///
  /// Throws [ApiKeyNotFoundException] when it does not exist or is not the
  /// caller's.
  Future<ApiKey> fetch(String id);

  /// Makes a key and returns it with its secret, which the server never shows
  /// again.
  Future<CreatedApiKey> create(ApiKeyCreate request);

  /// Applies [patch] to the key [id] and returns it as stored.
  ///
  /// Sends only what [patch] holds. Throws [ArgumentError] for an empty one.
  Future<ApiKey> update(String id, ApiKeyPatch patch);

  /// Deletes the key [id], which stops working at once.
  Future<void> delete(String id);
}

/// What a new key may do: exactly one of these.
sealed class ApiKeyGrant {
  const ApiKeyGrant();
}

/// A chosen list of permissions, sent as `scopes`.
@immutable
final class ApiKeyScopesGrant extends ApiKeyGrant {
  const ApiKeyScopesGrant(this.scopes);

  /// A scope with no pin leaves `resourceId` out of the JSON.
  final List<ApiKeyScope> scopes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApiKeyScopesGrant && _sameScopes(other.scopes, scopes);

  @override
  int get hashCode => Object.hashAll(scopes);

  @override
  String toString() => 'ApiKeyScopesGrant(${scopes.length} scopes)';
}

/// Every permission the caller may give, sent as `preset: 'everything'`.
@immutable
final class ApiKeyEverythingGrant extends ApiKeyGrant {
  const ApiKeyEverythingGrant();

  @override
  bool operator ==(Object other) => other is ApiKeyEverythingGrant;

  @override
  int get hashCode => (ApiKeyEverythingGrant).hashCode;

  @override
  String toString() => 'ApiKeyEverythingGrant()';
}

/// A new key to make (#1028).
@immutable
final class ApiKeyCreate {
  const ApiKeyCreate({
    required this.name,
    required this.grant,
    this.expiresInDays = ApiKeyRemoteDataSource.defaultExpiryDays,
    this.confirmCritical = false,
  });

  /// The key's name. The remote trims it and holds it to
  /// [ApiKeyRemoteDataSource.maxNameLength].
  final String name;

  final ApiKeyGrant grant;

  /// From [ApiKeyRemoteDataSource.minExpiryDays] to
  /// [ApiKeyRemoteDataSource.maxExpiryDays].
  final int expiresInDays;

  /// Sent as `confirmCritical: true` only when set, which is only after the
  /// user said yes to a Critical permission.
  final bool confirmCritical;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApiKeyCreate &&
          other.name == name &&
          other.grant == grant &&
          other.expiresInDays == expiresInDays &&
          other.confirmCritical == confirmCritical;

  @override
  int get hashCode => Object.hash(name, grant, expiresInDays, confirmCritical);

  @override
  String toString() =>
      'ApiKeyCreate(name: $name, grant: $grant, '
      'expiresInDays: $expiresInDays, confirmCritical: $confirmCritical)';
}

/// What changed on a key (#1028). A null field is left as it is, and is not
/// sent: never as `null`, and never as a `preset`.
@immutable
final class ApiKeyPatch {
  const ApiKeyPatch({
    this.name,
    this.enabled,
    this.scopes,
    this.expiresInDays,
    this.confirmCritical = false,
  });

  final String? name;
  final bool? enabled;

  /// The key's whole new list. Only sent when the user changed the
  /// permissions, so a key that holds a permission its owner has since lost
  /// can still be renamed.
  final List<ApiKeyScope>? scopes;

  /// Days from now, counted from the save.
  final int? expiresInDays;

  /// Sent as `confirmCritical: true` only when set. It is not a change.
  final bool confirmCritical;

  /// True when there is nothing to change. [confirmCritical] alone is not a
  /// change.
  bool get isEmpty =>
      name == null &&
      enabled == null &&
      scopes == null &&
      expiresInDays == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApiKeyPatch &&
          other.name == name &&
          other.enabled == enabled &&
          _sameScopes(other.scopes, scopes) &&
          other.expiresInDays == expiresInDays &&
          other.confirmCritical == confirmCritical;

  @override
  int get hashCode => Object.hash(
    name,
    enabled,
    scopes == null ? null : Object.hashAll(scopes!),
    expiresInDays,
    confirmCritical,
  );

  @override
  String toString() =>
      'ApiKeyPatch(name: $name, enabled: $enabled, '
      'scopes: ${scopes?.length}, expiresInDays: $expiresInDays, '
      'confirmCritical: $confirmCritical)';
}

bool _sameScopes(List<ApiKeyScope>? a, List<ApiKeyScope>? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null || a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Base class for every API key remote failure.
sealed class ApiKeyRemoteException implements Exception {
  const ApiKeyRemoteException(
    this.message, {
    this.statusCode,
    this.cause,
    this.apiMessage,
  });

  /// A description for logs. Never shown to the user. Never holds a secret.
  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  /// The `message` of the API's error envelope, when the refusal came from the
  /// API and the message is a string. The implementation fills it from there.
  ///
  /// The server translates it into the request's locale, so it is the words
  /// for a refusal this client has none of its own for.
  final String? apiMessage;

  @override
  String toString() =>
      // toString names the concrete subclass, so it needs the runtime type.
      // ignore: no_runtimetype_tostring
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// A 404 with code `API_KEY_NOT_FOUND`: no such key, or not the caller's.
final class ApiKeyNotFoundException extends ApiKeyRemoteException {
  const ApiKeyNotFoundException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
  });
}

/// A 403 with code `API_KEY_NEEDS_RECENT_SIGN_IN`: the session is too old, and
/// the user signs in again before trying once more.
final class ApiKeyNeedsRecentSignInException extends ApiKeyRemoteException {
  const ApiKeyNeedsRecentSignInException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
  });
}

/// A 422 with code `API_KEY_CRITICAL_NEEDS_CONFIRMATION`: the request holds a
/// Critical permission and did not confirm it.
final class ApiKeyCriticalNeedsConfirmationException
    extends ApiKeyRemoteException {
  const ApiKeyCriticalNeedsConfirmationException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
  });
}

/// A 403 with code `API_KEY_SESSION_REQUIRED`: the call was made with an API
/// key, and keys are only managed from a signed-in session.
final class ApiKeySessionRequiredException extends ApiKeyRemoteException {
  const ApiKeySessionRequiredException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
  });
}

/// A 422 with code `API_KEY_SCOPE_NOT_GRANTABLE`: the caller may not give the
/// permission [slug].
final class ApiKeyScopeNotGrantableException extends ApiKeyRemoteException {
  const ApiKeyScopeNotGrantableException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
    this.slug,
  });

  /// The permission the server refused. Null when the body did not name one.
  final String? slug;
}

/// A 422 with code `API_KEY_SCOPE_NOT_PINNABLE`: the permission [slug] cannot
/// be limited to one record.
final class ApiKeyScopeNotPinnableException extends ApiKeyRemoteException {
  const ApiKeyScopeNotPinnableException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
    this.slug,
  });

  /// The permission the server refused. Null when the body did not name one.
  final String? slug;
}

/// A 422 with code `API_KEY_EXPIRY_OUT_OF_RANGE`: the lifetime is outside what
/// the server allows.
final class ApiKeyExpiryOutOfRangeException extends ApiKeyRemoteException {
  const ApiKeyExpiryOutOfRangeException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
    this.min,
    this.max,
  });

  /// The fewest days the server allows. Null when the body did not say.
  final int? min;

  /// The most days the server allows. Null when the body did not say.
  final int? max;
}

/// The server refused the request, and sending it again will not change that.
final class ApiKeyPermanentException extends ApiKeyRemoteException {
  const ApiKeyPermanentException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class ApiKeyTransientException extends ApiKeyRemoteException {
  const ApiKeyTransientException(
    super.message, {
    super.statusCode,
    super.cause,
    super.apiMessage,
  });
}
