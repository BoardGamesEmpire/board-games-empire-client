import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

/// Assembles the per-server user-data export bundle (GDPR Article 20,
/// #11).
///
/// Pure coordinator over the registered exporters: no file IO. Saving the
/// returned bundle is the platform's `UserDataExportSink` (#92), and the
/// screen that drives it is the `data_export` feature (#93). Merging a
/// server-side bundle is still #94.
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
/// - `bgeClientVersion` is the client's version: [BuildInfo.version], the
///   root-scope singleton read once at boot (#35).
/// - `exportedAt` is ISO-8601 UTC, from the injected `now` clock
///   (injectable for deterministic tests).
/// - `serverId` and `serverName` are the server-vended identity of the
///   *data controller*: [ServerIdentity.serverId] and
///   [ServerIdentity.name] from [ActiveServer.identity], NOT the
///   client-local [ActiveServer.serverId] key or the locally-editable
///   [ActiveServer.displayName] nickname. The export is a legal-rights
///   artifact, so its server identity must be the authoritative values,
///   not one the user can rename.
/// - `userId` is the signed-in user's id, from the cached per-server
///   session ([AuthRepository.getCachedSession]). Export requires an
///   authenticated session.
/// - Only exporters returning non-null appear under `categories`, in
///   registration order. [UserDataExportBundle.unconfirmedKeys] names
///   the ones whose data the server hasn't confirmed.
///
/// ## Failure semantics
///
/// Every foreseeable lower-layer failure is mapped into the sealed
/// [UserDataExportException] hierarchy that #93's UI switches on:
/// - No session → [ExportNotAuthenticatedException]. No exporter runs
///   before this gate passes.
/// - A session that ends while the exporters run, or that belongs to a
///   different user by the time they finish → also
///   [ExportNotAuthenticatedException], and no bundle. An exporter that
///   finds the user's scope already torn down answers `null`, which would
///   otherwise leave its category silently out of a bundle the screen
///   reports as saved.
/// - Either session read itself fails (an `AuthException`) →
///   [ExportSessionUnavailableException], wrapping the originating
///   failure with its stack trace preserved
///   ([Error.throwWithStackTrace]).
///
/// Anything outside these anticipated failures (including exporter
/// errors) propagates unchanged: a GDPR export must be complete or fail
/// legibly, so a failing exporter fails the whole bundle fast rather
/// than silently dropping a category.
class UserDataExportBundler {
  UserDataExportBundler({
    required this._registry,
    required this._buildInfo,
    this._now = _defaultNow,
  });

  /// Version of the bundle format itself, independent of the client
  /// version. Bump only on a breaking envelope-shape change.
  static const int schemaVersion = 1;

  static DateTime _defaultNow() => DateTime.now();

  final UserDataExportRegistry _registry;
  final BuildInfo _buildInfo;
  final DateTime Function() _now;

  /// Assembles the export bundle for [server].
  ///
  /// [refresh] is passed to every exporter, asking it to bring its cache
  /// up to date first.
  ///
  /// Throws a [UserDataExportException] for every anticipated failure
  /// (see the class doc's *Failure semantics*). Exporter failures
  /// propagate unchanged.
  Future<UserDataExportBundle> assemble(
    ActiveServer server, {
    bool refresh = false,
  }) async {
    final session = await _readCachedSession(server);
    if (session == null) {
      throw const ExportNotAuthenticatedException();
    }

    final categories = <String, Object?>{};
    final unconfirmedKeys = <String>[];
    for (final exporter in _registry.exporters) {
      final export = await exporter.export(server, refresh: refresh);
      if (export != null) {
        categories[exporter.key] = export.data;
        if (!export.confirmed) {
          unconfirmedKeys.add(exporter.key);
        }
      }
    }

    // An exporter that found the user's scope torn down answered null;
    // only a session still held by the same user vouches for the bundle.
    final sessionAfter = await _readCachedSession(server);
    if (sessionAfter == null || sessionAfter.user.id != session.user.id) {
      throw const ExportNotAuthenticatedException();
    }

    return UserDataExportBundle(
      json: <String, Object?>{
        'schemaVersion': schemaVersion,
        'bgeClientVersion': _buildInfo.version,
        'exportedAt': _now().toUtc().toIso8601String(),
        'serverId': server.identity.serverId,
        'serverName': server.identity.name,
        'userId': session.user.id,
        'categories': categories,
      },
      unconfirmedKeys: List.unmodifiable(unconfirmedKeys),
    );
  }

  /// Reads the cached session, mapping any `AuthException` into
  /// [ExportSessionUnavailableException] while preserving the original
  /// stack trace. A `null` return is a settled "unauthenticated" answer
  /// and is handled by the caller.
  Future<AuthResponse?> _readCachedSession(ActiveServer server) async {
    final authRepository = server.container.get<AuthRepository>();
    try {
      return await authRepository.getCachedSession();
    } on AuthException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ExportSessionUnavailableException(cause: error),
        stackTrace,
      );
    }
  }
}
