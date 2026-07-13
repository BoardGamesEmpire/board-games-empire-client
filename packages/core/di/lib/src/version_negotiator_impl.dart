import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:pub_semver/pub_semver.dart';

/// Default [VersionNegotiator] backed by `pub_semver` (#13).
///
/// Stateless and const-constructible; safe to register as a singleton in
/// the root container or construct inline. All policy is documented on
/// the [VersionNegotiator] contract; this class only supplies the semver
/// mechanics:
///
/// - The client version comes from [BuildInfo.version]. An unparseable
///   value degrades to `0.0.0` — the same value `BuildInfo.unknown`
///   carries by design — so a server-declared minimum fails the client
///   *closed* rather than the parse error escaping into the caller.
/// - Server bounds are parsed tolerantly: a malformed bound is ignored
///   (open bound), matching the tolerant posture toward server-sent
///   well-known data.
/// - Bounds are inclusive on both ends. Pre-release ordering follows
///   semver: `1.0.0-beta` is older than `1.0.0`, so a pre-release client
///   fails a `minClientVersion` of the corresponding release.
final class VersionNegotiatorImpl implements VersionNegotiator {
  const VersionNegotiatorImpl();

  @override
  VersionNegotiationResult negotiate({
    required BuildInfo buildInfo,
    required ServerIdentity identity,
  }) {
    if (identity.wellKnownSchemaVersion > kSupportedWellKnownSchemaVersion) {
      return SchemaTooNew(serverSchemaVersion: identity.wellKnownSchemaVersion);
    }

    final client = _clientVersion(buildInfo);

    final minBound = _tryParse(identity.minClientVersion);
    if (minBound != null && client < minBound) {
      return ClientTooOld(
        clientVersion: buildInfo.version,
        requiredMinimum: identity.minClientVersion!,
      );
    }

    final maxBound = _tryParse(identity.maxClientVersion);
    if (maxBound != null && client > maxBound) {
      return ClientTooNew(
        clientVersion: buildInfo.version,
        supportedMaximum: identity.maxClientVersion!,
      );
    }

    return const VersionCompatible();
  }

  /// Parses the client's own version, degrading to the oldest possible
  /// version (`0.0.0`) when unparseable so bounded servers fail the
  /// client closed — the semantics `BuildInfo.unknown` was designed
  /// around.
  Version _clientVersion(BuildInfo buildInfo) =>
      _tryParse(buildInfo.version) ?? Version.none;

  /// Tolerant parse for server-sent bounds: null in, null out; malformed
  /// in, null out (open bound).
  Version? _tryParse(String? raw) {
    if (raw == null) return null;
    try {
      return Version.parse(raw);
    } on FormatException {
      return null;
    }
  }
}
