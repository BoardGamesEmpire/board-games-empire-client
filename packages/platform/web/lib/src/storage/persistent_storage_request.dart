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
///
/// ## A refusal pauses the asking
///
/// Given `refusals`, a refusal is remembered across page loads, and for
/// [refusalPause] after it no page load asks again. That is for Firefox,
/// the one browser that asks the user: a prompt dismissed without an answer
/// reads as a refusal, and asking on every page load would put the prompt
/// back each time. `persist` answers the same for a dismissal and a refusal,
/// so both pause. Without `refusals` every page load asks once, which suits
/// a browser that decides silently and may grant later.
final class PersistentStorageRequest {
  PersistentStorageRequest({
    required this._persisted,
    required this._persist,
    this._refusals,
    DateTime Function()? now,
    BgeLogger? logger,
  }) : _now = now ?? DateTime.now,
       _logger = logger ?? BgeLogger('bge.platform.web_storage');

  /// How long after a refusal no page load asks again.
  static const Duration refusalPause = Duration(days: 30);

  final Future<bool> Function() _persisted;
  final Future<bool> Function() _persist;
  final PersistRefusals? _refusals;
  final DateTime Function() _now;
  final BgeLogger _logger;

  Future<void>? _request;

  /// Asks once per instance; later calls return the first call's future, and
  /// call nothing. Never throws.
  Future<void> requestOnce() => _request ??= _ask();

  Future<void> _ask() async {
    try {
      if (await _persisted()) {
        _forgetRefusal();
        _logger.info('persistent storage: already granted');
        return;
      }
      final refusedAt = _readRefusal();
      if (refusedAt != null && _now().isBefore(refusedAt.add(refusalPause))) {
        _logger.info(
          'persistent storage: not asked; refused at '
          '${refusedAt.toIso8601String()}, so asked again '
          '${refusalPause.inDays} days after that',
        );
        return;
      }
      if (await _persist()) {
        _forgetRefusal();
        _logger.info('persistent storage: granted');
      } else {
        _rememberRefusal();
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

  // The record is a convenience: one the browser won't read or write
  // (storage blocked, a private window) leaves the asking as it would be
  // without it, and is no failure of the request.

  DateTime? _readRefusal() {
    try {
      return _refusals?.read();
    } on Object {
      return null;
    }
  }

  void _rememberRefusal() {
    try {
      _refusals?.write(_now());
    } on Object {
      // See above.
    }
  }

  void _forgetRefusal() {
    try {
      _refusals?.write(null);
    } on Object {
      // See above.
    }
  }
}

/// Where [PersistentStorageRequest] remembers a refusal across page loads
/// (#320). The browser's is `localStorage`, which is per origin like the
/// grant itself.
abstract interface class PersistRefusals {
  /// When the last refusal was, or null when there is none to remember.
  DateTime? read();

  /// Records [refusedAt], or forgets the refusal when it is null.
  void write(DateTime? refusedAt);
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
