import 'package:models/domain.dart';

/// Remote data source for the caller's own profile (#547).
///
/// There is no local copy: the profile screen reads through this each time it
/// opens, and a save goes straight to the server.
///
/// Implementations run over a **per-server** authenticated transport, like
/// [UserRemoteDataSource]: the injected client carries the base URL and the
/// session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/user` (`profile/user-profile.controller.ts`), under the
/// `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchOwn] | `GET /api/users/me/profile` | `{ profile: {...} }` |
/// | [updateOwn] | `PATCH /api/users/me/profile` | the changed fields; `{ profile: {...} }` |
///
/// The server leaves a field it did not get as it is, and a text field or
/// the preferred player count sent as `null` is cleared. The owner's answer
/// carries the owner-only fields.
///
/// ## Failures
///
/// - [UserProfileNotFoundException]: an enveloped 404 that is not
///   `ROUTE_NOT_FOUND`. The caller has no profile row. A missing route is
///   another thing: a server that does not have this route yet, or a proxy
///   in front of it, which a later attempt may get past, so it stays
///   transient.
/// - [UserProfileRefusedException]: an enveloped 403, from either route. The
///   server refuses the caller: its permissions don't allow the request, or,
///   on a save, the server's update conditions exclude the caller's row.
/// - [UserProfileTransientException] and [UserProfilePermanentException]: the
///   shared rules. A 400, including the empty body the server refuses, is
///   permanent.
/// - [ArgumentError], unwrapped, from [updateOwn]: an empty patch, a
///   [Reach.unknown], a display name that is blank after trimming, a
///   preferred player count outside `minPlayerCount..maxPlayerCount`, or a
///   text longer than its cap by `serverStringLength`. The server trims
///   every text but the bio before it counts, so those are measured after
///   `trim()` and the bio as sent.
abstract class UserProfileRemoteDataSource {
  /// The longest display name the server takes, after trimming.
  static const int maxDisplayNameLength = 64;

  /// The longest bio the server takes. It is not trimmed: leading spaces are
  /// Markdown structure.
  static const int maxBioLength = 2000;

  /// The longest pronouns the server takes, after trimming.
  static const int maxPronounsLength = 40;

  /// The longest location the server takes, after trimming.
  static const int maxLocationLength = 100;

  /// The longest house rules preference the server takes, after trimming.
  static const int maxHouseRulesLength = 200;

  /// The longest dietary restrictions or accessibility needs the server
  /// takes, after trimming.
  static const int maxPracticalInfoLength = 500;

  /// The lowest preferred player count the server takes.
  static const int minPlayerCount = 1;

  /// The highest preferred player count the server takes.
  static const int maxPlayerCount = 100;

  /// The caller's profile, as its owner sees it.
  Future<UserProfile> fetchOwn();

  /// Applies [patch] to the caller's profile and returns the stored result.
  ///
  /// Throws [ArgumentError] for an invalid [patch], before any request.
  Future<UserProfile> updateOwn(ProfilePatch patch);
}

/// Base class for every profile remote failure.
sealed class UserProfileRemoteException implements Exception {
  const UserProfileRemoteException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  /// A description for logs. Never shown to the user.
  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      // toString names the concrete subclass, so it needs the runtime type.
      // ignore: no_runtimetype_tostring
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The server refused the request, and sending it again will not change that.
final class UserProfilePermanentException extends UserProfileRemoteException {
  const UserProfilePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class UserProfileTransientException extends UserProfileRemoteException {
  const UserProfileTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// An enveloped 404 that is not a missing route: the caller has no profile.
final class UserProfileNotFoundException extends UserProfileRemoteException {
  const UserProfileNotFoundException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// An enveloped 403: the server refuses the caller, for its permissions on
/// either route, or, on a save, because the server's update conditions
/// exclude the caller's profile.
final class UserProfileRefusedException extends UserProfileRemoteException {
  const UserProfileRefusedException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
