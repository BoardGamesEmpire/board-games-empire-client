import 'package:freezed_annotation/freezed_annotation.dart';

import 'server_config.dart';
import 'server_identity.dart';

part 'scoped_server.freezed.dart';

/// The server a per-user dependency scope is being installed for (#137).
///
/// `UserScopeInstaller.install` used to take the whole [ServerConfig], which
/// made the seam native-only: web has no persisted config by construction —
/// the browser can only talk to the origin in the address bar, and its
/// per-server identifier is the fetched [ServerIdentity]. Every user-scope
/// installer in the tree reads exactly two things off that config, both for
/// diagnostics, so the seam now asks for exactly those two things and each
/// platform supplies them from what it actually has.
///
/// Deliberately **not** a synthesized `ServerConfig`. That would be a
/// one-liner, and it would require fabricating `id` (a cuid used as a DB
/// primary key), `connectionState` and `lastIdentityFetchedAt` — values that
/// feed database paths and staleness checks, so the fake would have to stay
/// correct forever, in a package with no reason to know web exists.
///
/// ## The id is server-vended on both platforms
///
/// [serverId] is the `bge_server_id` UUID the server vends in its well-known
/// document: `ServerConfig.bgeServerId` on native, `ServerIdentity.serverId`
/// on web. It is deliberately *not* `ActiveServer.serverId`, which is the
/// client-local cuid on native and the server-vended UUID on web — see #334.
/// A diagnostic naming a server should mean the same thing wherever it was
/// written.
///
/// [displayName] is the name a human would recognise, which is not the same
/// question: native uses the local alias the user chose during server-add
/// (`ServerConfig.displayName`), web the name the server advertises
/// (`ServerIdentity.name`), because web has no server-add flow to choose one
/// in.
@freezed
abstract class ScopedServer with _$ScopedServer {
  const ScopedServer._();

  const factory ScopedServer({
    /// The stable server-vended UUID (`bge_server_id`).
    required String serverId,

    /// Human-readable server name, for diagnostics and attribution.
    required String displayName,
  }) = _ScopedServer;

  /// The native leg: a configured server the user added on this device.
  factory ScopedServer.fromConfig(ServerConfig config) => ScopedServer(
    serverId: config.bgeServerId,
    displayName: config.displayName,
  );

  /// The web leg: the serving origin, whose identity was fetched at
  /// bootstrap and which has no persisted config behind it (#96).
  factory ScopedServer.fromIdentity(ServerIdentity identity) =>
      ScopedServer(serverId: identity.serverId, displayName: identity.name);
}
