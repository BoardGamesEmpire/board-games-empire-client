import 'package:models/domain.dart';

/// Newest /.well-known/bge-identity document schema version this client
/// understands. A server advertising a higher `wellKnownSchemaVersion`
/// may have restructured the document in ways this client would misread,
/// so negotiation refuses it outright ([SchemaTooNew]).
const int kSupportedWellKnownSchemaVersion = 1;

/// Decides whether this client may talk to a server, based on the
/// server's advertised compatibility bounds (#13).
///
/// Called with a freshly fetched [ServerIdentity] **before** any
/// `ServerConfig` is persisted (#36 server-add) and, later, on identity
/// refresh (#87). A non-[VersionCompatible] result must prevent the
/// server from being persisted or used.
///
/// Pure and synchronous: no I/O, no state. The client's own version
/// arrives via [BuildInfo] (#35), read once at startup.
abstract interface class VersionNegotiator {
  /// Evaluates [identity]'s compatibility constraints against
  /// [buildInfo].
  ///
  /// Check order (first failure wins):
  /// 1. Document schema: `wellKnownSchemaVersion` newer than
  ///    [kSupportedWellKnownSchemaVersion] → [SchemaTooNew]. Checked
  ///    first because a newer schema means the remaining fields may not
  ///    mean what this client thinks they mean.
  /// 2. Minimum bound: client older than `minClientVersion` →
  ///    [ClientTooOld]. The bound is inclusive: a client exactly at the
  ///    minimum passes.
  /// 3. Maximum bound: client newer than `maxClientVersion` →
  ///    [ClientTooNew]. Also inclusive.
  ///
  /// Failure policy (established with `BuildInfo.unknown`, #35): an
  /// unparseable **client** version is treated as `0.0.0` — oldest
  /// possible — so negotiation fails *closed* against a server that
  /// declares a minimum. An unparseable **server** bound is ignored
  /// (treated as an open bound): a server operator's typo must not brick
  /// every client, and tolerant parsing of server-sent data is the
  /// established well-known posture.
  VersionNegotiationResult negotiate({
    required BuildInfo buildInfo,
    required ServerIdentity identity,
  });
}

/// Outcome of a [VersionNegotiator.negotiate] call.
///
/// Exhaustively handle with a `switch` expression:
/// ```dart
/// final message = switch (result) {
///   VersionCompatible() => null,
///   ClientTooOld(:final requiredMinimum) => l10n.clientTooOld(requiredMinimum),
///   ClientTooNew(:final supportedMaximum) => l10n.clientTooNew(supportedMaximum),
///   SchemaTooNew() => l10n.schemaTooNew,
/// };
/// ```
///
/// Payload fields carry raw version strings for interpolation into
/// localized messages (#36); no formatting is baked in here.
sealed class VersionNegotiationResult {
  const VersionNegotiationResult();
}

/// The client may proceed: schema understood, version within bounds
/// (or bounds open).
final class VersionCompatible extends VersionNegotiationResult {
  const VersionCompatible();

  @override
  bool operator ==(Object other) => other is VersionCompatible;

  @override
  int get hashCode => (VersionCompatible).hashCode;

  @override
  String toString() => 'VersionCompatible()';
}

/// The client is older than the server's `minClientVersion`.
/// The user should update the client.
final class ClientTooOld extends VersionNegotiationResult {
  const ClientTooOld({
    required this.clientVersion,
    required this.requiredMinimum,
  });

  /// The client's own version string, as reported by [BuildInfo].
  final String clientVersion;

  /// The server's `minClientVersion`, verbatim from the identity
  /// document.
  final String requiredMinimum;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientTooOld &&
          other.clientVersion == clientVersion &&
          other.requiredMinimum == requiredMinimum;

  @override
  int get hashCode => Object.hash(clientVersion, requiredMinimum);

  @override
  String toString() =>
      'ClientTooOld(clientVersion: $clientVersion, '
      'requiredMinimum: $requiredMinimum)';
}

/// The client is newer than the server's `maxClientVersion`.
/// The user should use an older client or wait for the server to update.
final class ClientTooNew extends VersionNegotiationResult {
  const ClientTooNew({
    required this.clientVersion,
    required this.supportedMaximum,
  });

  /// The client's own version string, as reported by [BuildInfo].
  final String clientVersion;

  /// The server's `maxClientVersion`, verbatim from the identity
  /// document.
  final String supportedMaximum;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientTooNew &&
          other.clientVersion == clientVersion &&
          other.supportedMaximum == supportedMaximum;

  @override
  int get hashCode => Object.hash(clientVersion, supportedMaximum);

  @override
  String toString() =>
      'ClientTooNew(clientVersion: $clientVersion, '
      'supportedMaximum: $supportedMaximum)';
}

/// The identity document uses a schema newer than this client
/// understands. The user should update the client.
final class SchemaTooNew extends VersionNegotiationResult {
  const SchemaTooNew({
    required this.serverSchemaVersion,
    this.supportedSchemaVersion = kSupportedWellKnownSchemaVersion,
  });

  /// The `wellKnownSchemaVersion` the server advertised.
  final int serverSchemaVersion;

  /// The newest schema version this client understands.
  final int supportedSchemaVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SchemaTooNew &&
          other.serverSchemaVersion == serverSchemaVersion &&
          other.supportedSchemaVersion == supportedSchemaVersion;

  @override
  int get hashCode => Object.hash(serverSchemaVersion, supportedSchemaVersion);

  @override
  String toString() =>
      'SchemaTooNew(serverSchemaVersion: $serverSchemaVersion, '
      'supportedSchemaVersion: $supportedSchemaVersion)';
}
