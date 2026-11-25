import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:meta/meta.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Why a request about an API key failed, as the screens word it (#1028).
enum ApiKeyFailureReason {
  /// The session is too old: the user signs in again first.
  needsRecentSignIn,

  /// A Critical permission went without the user's confirmation.
  criticalNeedsConfirmation,

  /// The user may not give the permission [ApiKeyFailure.slug].
  scopeNotGrantable,

  /// The permission [ApiKeyFailure.slug] can't be limited to one record.
  scopeNotPinnable,

  /// The lifetime is outside [ApiKeyFailure.min] to [ApiKeyFailure.max].
  expiryOutOfRange,

  /// The key doesn't exist, or isn't the user's.
  notFound,

  /// No answer from the server that said anything; trying later may work.
  transient,

  /// A refusal this client has no words of its own for. Its words are the
  /// server's [ApiKeyFailure.serverMessage], when it gave one.
  generic,
}

/// A failed request about an API key, with what the refusal named (#1028).
///
/// Never holds a key's secret: it is built from the remote's exceptions,
/// which never carry one.
@immutable
final class ApiKeyFailure {
  const ApiKeyFailure(
    this.reason, {
    this.slug,
    this.min,
    this.max,
    this.serverMessage,
  });

  final ApiKeyFailureReason reason;

  /// The permission a scope refusal named, when it named one.
  final String? slug;

  /// The fewest days a key may last, when an expiry refusal said.
  final int? min;

  /// The most days a key may last, when an expiry refusal said.
  final int? max;

  /// The message of the API's error envelope, in the request's locale, when
  /// the refusal came from the API. Shown for a [ApiKeyFailureReason.generic]
  /// refusal, which has no words of the client's own.
  final String? serverMessage;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApiKeyFailure &&
          other.reason == reason &&
          other.slug == slug &&
          other.min == min &&
          other.max == max &&
          other.serverMessage == serverMessage;

  @override
  int get hashCode => Object.hash(reason, slug, min, max, serverMessage);

  @override
  String toString() =>
      'ApiKeyFailure(${reason.name}, slug: $slug, min: $min, max: $max)';
}

/// [error] as an [ApiKeyFailure]: each [ApiKeyRemoteException] by its kind,
/// and anything else as [ApiKeyFailureReason.generic].
///
/// [ApiKeySessionRequiredException], a key used to manage keys, is generic
/// too: a signed-in session is the only way this client calls, so it has no
/// words of its own for it, and shows the server's.
ApiKeyFailure apiKeyFailureOf(Object error) {
  if (error is! ApiKeyRemoteException) {
    return const ApiKeyFailure(ApiKeyFailureReason.generic);
  }
  final said = error.apiMessage;
  return switch (error) {
    ApiKeyNeedsRecentSignInException() => ApiKeyFailure(
      ApiKeyFailureReason.needsRecentSignIn,
      serverMessage: said,
    ),
    ApiKeyCriticalNeedsConfirmationException() => ApiKeyFailure(
      ApiKeyFailureReason.criticalNeedsConfirmation,
      serverMessage: said,
    ),
    ApiKeyScopeNotGrantableException(:final slug) => ApiKeyFailure(
      ApiKeyFailureReason.scopeNotGrantable,
      slug: slug,
      serverMessage: said,
    ),
    ApiKeyScopeNotPinnableException(:final slug) => ApiKeyFailure(
      ApiKeyFailureReason.scopeNotPinnable,
      slug: slug,
      serverMessage: said,
    ),
    ApiKeyExpiryOutOfRangeException(:final min, :final max) => ApiKeyFailure(
      ApiKeyFailureReason.expiryOutOfRange,
      min: min,
      max: max,
      serverMessage: said,
    ),
    ApiKeyNotFoundException() => ApiKeyFailure(
      ApiKeyFailureReason.notFound,
      serverMessage: said,
    ),
    ApiKeyTransientException() => ApiKeyFailure(
      ApiKeyFailureReason.transient,
      serverMessage: said,
    ),
    ApiKeyPermanentException() || ApiKeySessionRequiredException() =>
      ApiKeyFailure(ApiKeyFailureReason.generic, serverMessage: said),
  };
}

/// The words for [failure].
///
/// A refusal with words of the client's own shows them. A generic one shows
/// the server's message when it gave one, and the client's generic words
/// otherwise (#1028: refusals are announced with the server's message where
/// the client has none of its own).
///
/// A scope refusal names the permission by its description in [grantable],
/// and by its slug when [grantable] doesn't have it. An expiry refusal that
/// named no range uses the client's own.
String apiKeyFailureMessage(
  ApiKeysLocalizations l10n,
  ApiKeyFailure failure, {
  Map<String, GrantablePermission>? grantable,
}) {
  String? permission() => switch (failure.slug) {
    final slug? => grantable?[slug]?.description ?? slug,
    null => null,
  };
  return switch (failure.reason) {
    ApiKeyFailureReason.needsRecentSignIn =>
      l10n.apiKeyFailureNeedsRecentSignIn,
    ApiKeyFailureReason.criticalNeedsConfirmation =>
      l10n.apiKeyFailureCriticalNeedsConfirmation,
    ApiKeyFailureReason.scopeNotGrantable => switch (permission()) {
      final named? => l10n.apiKeyFailureScopeNotGrantable(named),
      null => l10n.apiKeyFailureScopeUnnamed,
    },
    ApiKeyFailureReason.scopeNotPinnable => switch (permission()) {
      final named? => l10n.apiKeyFailureScopeNotPinnable(named),
      null => l10n.apiKeyFailureScopeUnpinnableUnnamed,
    },
    ApiKeyFailureReason.expiryOutOfRange => l10n.apiKeyFailureExpiryOutOfRange(
      failure.min ?? ApiKeyRemoteDataSource.minExpiryDays,
      failure.max ?? ApiKeyRemoteDataSource.maxExpiryDays,
    ),
    ApiKeyFailureReason.notFound => l10n.apiKeyFailureNotFound,
    ApiKeyFailureReason.transient => l10n.apiKeyFailureTransient,
    ApiKeyFailureReason.generic => switch (failure.serverMessage?.trim()) {
      final said? when said.isNotEmpty => said,
      _ => l10n.apiKeyFailureGeneric,
    },
  };
}
