import 'dart:async';

import 'package:interfaces/orchestration.dart'
    show DependencyContainer, UserScopeInstaller;
import 'package:models/domain.dart' show ScopedServer;
import 'package:observability/observability.dart' show BgeLogger;

/// Asks the browser to keep this origin's stored data, once (#320).
///
/// A browser may clear an origin's storage under pressure unless the origin
/// holds a `navigator.storage.persist()` grant. The web database and the
/// feedback queue both live in that storage, on the same terms. This asks for
/// the grant so that data the server does not have yet, the sync queue and
/// approved feedback reports among it, is less likely to be evicted. The
/// stores' own promise is unchanged either way: they say the data is stored,
/// not that the browser will keep it.
///
/// The browser's two calls come in as functions, so this stays
/// VM-compilable: `persisted` is `navigator.storage.persisted()` and
/// `persist` is `navigator.storage.persist()`. Each throws when the browser
/// has no `navigator.storage`; that is logged, never rethrown.
///
/// The answer is logged on `bge.platform.web_storage`, the storage report's
/// logger: `info` for a grant, or storage that was already persistent, `warn`
/// for a refusal or a failure.
final class PersistentStorageRequest {
  PersistentStorageRequest({
    required this._persisted,
    required this._persist,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.platform.web_storage');

  final Future<bool> Function() _persisted;
  final Future<bool> Function() _persist;
  final BgeLogger _logger;

  Future<void>? _request;

  /// Asks once per instance; later calls return the first call's future, and
  /// call nothing. Never throws.
  Future<void> requestOnce() => _request ??= _ask();

  Future<void> _ask() async {
    try {
      if (await _persisted()) {
        _logger.info('persistent storage: already granted');
        return;
      }
      if (await _persist()) {
        _logger.info('persistent storage: granted');
      } else {
        _logger.warn(
          'persistent storage: the browser refused the request, so it may '
          'clear stored data under storage pressure',
        );
      }
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'persistent storage: the request failed, so the browser may clear '
        'stored data under storage pressure',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// A user-scope installer that starts a persistent-storage request when a
/// user session starts, by a sign-in or by restoring a stored session
/// (#320).
///
/// It resolves nothing and depends on nothing, so it can run anywhere in the
/// list, and it never throws or waits: the request is unawaited, and a
/// failure is swallowed, because a throw from `install` would abort the
/// sign-in. The caller's [PersistentStorageRequest.requestOnce] makes it ask
/// once per page load, however many times a user signs in.
final class PersistentStorageRequestInstaller implements UserScopeInstaller {
  const PersistentStorageRequestInstaller(this._request);

  final Future<void> Function() _request;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _request();
    } on Object {
      // Best-effort: the request logs its own failures, and a sign-in must
      // not depend on it.
    }
  }
}
