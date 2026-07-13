import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

/// Assembles the per-server user-data export bundle (GDPR Article 20,
/// #11).
///
/// Pure coordinator: no file IO and no new dependencies. Persistence of
/// the returned bundle (file picker / web download) is #92; the
/// confirmation UI is #93; merging the server-side bundle is #94.
///
/// ## Envelope
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "bgeClientVersion": "0.1.0",
///   "exportedAt": "2026-05-17T19:33:00.000Z",
///   "serverId": "<bgeServerId>",
///   "serverName": "Example BGE",
///   "userId": "...",
///   "categories": { "gameCollection": { "entries": [] } }
/// }
/// ```
///
/// - `schemaVersion` versions the bundle *format*, independent of the
///   client version ([schemaVersion]).
/// - `bgeClientVersion` is [BuildInfo.version] — the root-scope
///   singleton read once at boot (#35).
/// - `exportedAt` is ISO-8601 UTC from the injected [now] clock,
///   injectable for deterministic tests.
/// - `serverId` is the stable, server-vended [ServerConfig.bgeServerId]
///   and `serverName` is the server-vended [ServerIdentity.name] from
///   the cached identity — NOT the locally-editable
///   [ServerConfig.displayName] nickname. Both name the *data
///   controller*: the export is a legal-rights artifact, so its server
///   identity must be the authoritative server-vended values, not a
///   value the user can rename.
/// - `userId` comes from the cached per-server session
///   ([AuthRepository.getCachedSession]). Export requires an
///   authenticated session.
/// - Only exporters returning non-null appear under `categories`, in
///   registration order.
///
/// ## Failure semantics
///
/// Every foreseeable lower-layer failure is mapped into the sealed
/// [UserDataExportException] hierarchy that #93's UI switches on:
/// - No session ([AuthRepository.getCachedSession] returns null) →
///   [ExportNotAuthenticatedException].
/// - The session read itself fails (e.g. `AuthNetworkException` when a
///   web client is offline — the cached-session read delegates to the
///   network on web) → [ExportSessionUnavailableException], wrapping the
///   originating `AuthException`.
/// - No server config, or an unreadable cached identity
///   (`CorruptedServerIdentityException`), for
///   [ServerContext.serverId] → [ExportUnknownServerException].
///
/// Wrapping preserves the original stack trace via
/// [Error.throwWithStackTrace]. Anything outside these anticipated
/// failures (including exporter errors) propagates unchanged — a GDPR
/// export must be complete or fail legibly, so a failing exporter fails
/// the whole bundle fast rather than silently dropping a category.
/// Sequencing is pinned by tests: no server lookup and no exporter runs
/// before the session gate passes.
class UserDataExportBundler {
  UserDataExportBundler({
    required UserDataExportRegistry registry,
    required ServerRepository serverRepository,
    required BuildInfo buildInfo,
    DateTime Function() now = _defaultNow,
  }) : _registry = registry,
       _serverRepository = serverRepository,
       _buildInfo = buildInfo,
       _now = now;

  static DateTime _defaultNow() => DateTime.now();

  /// Version of the bundle format itself, independent of the client
  /// version. Bump only on a breaking envelope-shape change.
  static const int schemaVersion = 1;

  final UserDataExportRegistry _registry;
  final ServerRepository _serverRepository;
  final BuildInfo _buildInfo;
  final DateTime Function() _now;

  /// Assembles the export bundle for the server represented by
  /// [context].
  ///
  /// Throws a [UserDataExportException] for every anticipated failure
  /// (see the class doc's *Failure semantics*). Exporter failures
  /// propagate unchanged.
  Future<Map<String, Object?>> assemble(ServerContext context) async {
    final session = await _readCachedSession(context);
    if (session == null) {
      throw const ExportNotAuthenticatedException();
    }

    final config = await _resolveServerConfig(context.serverId);
    if (config == null) {
      throw ExportUnknownServerException(serverId: context.serverId);
    }

    final categories = <String, Object?>{};
    for (final exporter in _registry.exporters) {
      final payload = await exporter.export(context);
      if (payload != null) {
        categories[exporter.key] = payload;
      }
    }

    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'bgeClientVersion': _buildInfo.version,
      'exportedAt': _now().toUtc().toIso8601String(),
      'serverId': config.bgeServerId,
      'serverName': config.cachedIdentity.name,
      'userId': session.user.id,
      'categories': categories,
    };
  }

  /// Reads the cached session, mapping any `AuthException` (e.g. a web
  /// offline network failure) into [ExportSessionUnavailableException]
  /// while preserving the original stack trace. A `null` return is a
  /// settled "unauthenticated" answer and is handled by the caller.
  Future<AuthResponse?> _readCachedSession(ServerContext context) async {
    final authRepository = context.container.get<AuthRepository>();
    try {
      return await authRepository.getCachedSession();
    } on AuthException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ExportSessionUnavailableException(cause: error),
        stackTrace,
      );
    }
  }

  /// Resolves the [ServerConfig] for [serverId], mapping an unreadable
  /// cached identity (`CorruptedServerIdentityException`) into
  /// [ExportUnknownServerException] while preserving the original stack
  /// trace. A `null` return (no such server) is handled by the caller.
  Future<ServerConfig?> _resolveServerConfig(String serverId) async {
    try {
      return await _serverRepository.getServer(serverId);
    } on CorruptedServerIdentityException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ExportUnknownServerException(serverId: serverId, cause: error),
        stackTrace,
      );
    }
  }
}
