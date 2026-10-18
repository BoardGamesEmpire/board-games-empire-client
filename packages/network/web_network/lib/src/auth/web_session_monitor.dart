import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart'
    show AuthState, AuthStateAuthenticated, AuthStateUnknown;
import 'package:observability/observability.dart';

import 'session_channel.dart';
import 'web_auth_repository_impl.dart';

/// Keeps one tab's session in step with the cookie every tab shares (#432).
///
/// The session is an httpOnly cookie every tab of the origin sends, while
/// each tab's idea of who is signed in lives in its own memory. A sign-in in
/// one tab moved the cookie under the others, which went on presenting the
/// previous user while every request they made acted as the new one.
///
/// Three things now reach a tab:
///
/// - **A broadcast** from another tab, over [SessionChannel]. A sign-out
///   ends the session here with the latch up
///   ([WebAuthRepositoryImpl.signedOutInAnotherTab]); a sign-in counts as a
///   grant and re-reads the cookie
///   ([WebAuthRepositoryImpl.signedInInAnotherTab]). This tab's own changes
///   go out the same way.
/// - **The page regaining attention** — focus, or turning visible. Delivery
///   is not guaranteed to a frozen or discarded page, so this re-reads the
///   cookie as the backstop. Not past a sign-out heard here, though: its
///   latch refuses every read until a grant, so a tab that then misses the
///   sign-in broadcast stays on the sign-in form over the new session. That
///   fails closed, and the alternative is a re-read adopting a cookie the
///   other tab's revocation may have failed to end.
/// - **[confirm]**, asked by work about to send as the session.
///
/// A re-read moves the repository to whatever the cookie says. `AuthBloc`
/// mirrors the repository, so a new user reaches the shell, which switches
/// sessions; nothing here touches the UI.
///
/// Below the widget tree on purpose. A widget above the router would tie
/// this to route placement, and routes outside the auth shell already miss
/// the resume revalidation for that reason (#145).
///
/// ## What [confirm] leaves open
///
/// A request already on its way when the cookie changes. Its window is as
/// long as a broadcast takes to arrive, and only the server can close it:
/// backend#793 lets a request name the user it means to act as.
class WebSessionMonitor implements SessionIdentityGuard, Disposable {
  WebSessionMonitor({
    required this._repository,
    required this._channel,
    required Stream<void> attention,
  }) {
    _subscriptions
      ..add(_channel.changes.listen(_onBroadcast))
      ..add(_repository.localChanges.listen(_channel.post))
      ..add(attention.listen((_) => _onAttention()))
      ..add(_repository.watchAuthState().listen(_onAuthState));
  }

  final WebAuthRepositoryImpl _repository;
  final SessionChannel _channel;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final BgeLogger _log = BgeLogger('bge.web.auth.session_monitor');

  /// Moves on every event that can change whose cookie this is: the page
  /// regaining attention, and a broadcast. A read only counts towards
  /// [_verified] if no event landed while it was out.
  int _epoch = 0;

  /// Whether a read of the session finished since the last event, so the
  /// repository's state is the cookie's answer rather than an older one.
  bool _verified = false;

  /// The read every caller of the current epoch shares.
  Future<void>? _inFlight;
  int _inFlightEpoch = -1;

  /// The epoch the last attention event opened, or -1 once a broadcast has
  /// opened a newer one.
  int _attentionEpoch = -1;

  /// Whether a sign-in broadcast arrived during the startup check, which
  /// then owes a read once it has decided.
  bool _rereadOwed = false;

  /// Whether the cookie is [userId]'s, by the repository's state once a read
  /// since the last event has settled it.
  ///
  /// Calls made together share one read, and the answer holds until the
  /// page regains attention or a broadcast arrives. This tab's own sign-in
  /// and sign-out need no read: they set the repository's state from the
  /// cookie they changed.
  ///
  /// It waits one task before looking. The rehydrate trigger hears focus
  /// through Flutter's lifecycle and this class through its own listener,
  /// both inside one dispatch, and which runs first is up to the engine. A
  /// hydrate the trigger starts can therefore ask before this has heard the
  /// event that voids the answer it holds. A task later, every listener of
  /// that dispatch has run.
  @override
  Future<SessionConfirmation> confirm(String userId) async {
    await Future<void>.delayed(Duration.zero);
    while (true) {
      final epoch = _epoch;
      if (!_verified) {
        try {
          await _sharedRead();
        } on Object catch (error) {
          _log.warn(
            'Could not confirm whose session this is; the caller holds off',
            context: {'cause': error.runtimeType.toString()},
          );
          return SessionConfirmation.unanswered;
        }
      }
      if (epoch == _epoch) {
        return switch (_repository.currentAuthState) {
          AuthStateAuthenticated(:final session)
              when session.user.id == userId =>
            SessionConfirmation.confirmed,
          _ => SessionConfirmation.notThisUser,
        };
      }
    }
  }

  void _invalidate() {
    _epoch += 1;
    _verified = false;
  }

  /// Reads the session, or joins a read already asked for since the last
  /// event.
  ///
  /// A read from before an event is not joined, and not raced either: the new
  /// one waits for it. Two reads out at once could resolve out of order, and
  /// the older answer would then overwrite the newer in the repository.
  Future<void> _sharedRead() {
    final epoch = _epoch;
    final pending = _inFlight;
    if (pending != null && _inFlightEpoch == epoch) return pending;

    late final Future<void> read;
    read = _readAfterPrevious(pending, epoch).whenComplete(() {
      if (identical(_inFlight, read)) _inFlight = null;
    });
    _inFlight = read;
    _inFlightEpoch = epoch;
    return read;
  }

  Future<void> _readAfterPrevious(Future<void>? previous, int epoch) async {
    if (previous != null) {
      // Its own callers hear how it ended.
      await previous.then<void>((_) {}, onError: (Object _) {});
    }
    await _repository.rereadSession();
    if (epoch == _epoch) _verified = true;
  }

  void _onBroadcast(SessionChange change) {
    _invalidate();
    _attentionEpoch = -1;
    switch (change) {
      case SessionChange.signedOut:
        _repository.signedOutInAnotherTab();
      case SessionChange.signedIn:
        _repository.signedInInAnotherTab();
        // The startup check's read may have left before the other tab's
        // cookie existed, so its answer can be the old one. Read again once
        // it has decided ([_onAuthState]).
        if (_repository.currentAuthState is AuthStateUnknown) {
          _rereadOwed = true;
        } else {
          unawaited(_rereadAfterEvent());
        }
    }
  }

  void _onAttention() {
    // Switching back to a tab fires visibilitychange and then focus. A read
    // that left after the first one already answers for the second, unless
    // a broadcast came between them.
    final readSinceLastAttention =
        _attentionEpoch == _epoch &&
        _inFlight != null &&
        _inFlightEpoch == _epoch;
    if (readSinceLastAttention) return;
    _invalidate();
    _attentionEpoch = _epoch;
    unawaited(_rereadAfterEvent());
  }

  /// Pays the read a sign-in broadcast during the startup check owed, once
  /// the check has decided.
  ///
  /// The repository decides inside the check's own read, a moment before
  /// the bloc's check emits. The read this starts is a round trip later,
  /// by which time the bloc mirrors the repository again.
  void _onAuthState(AuthState state) {
    if (!_rereadOwed || state is AuthStateUnknown) return;
    _rereadOwed = false;
    unawaited(_rereadAfterEvent());
  }

  /// Re-reads the session, which moves the repository to whatever the cookie
  /// now says.
  ///
  /// Not while the startup check is still deciding (the repository still
  /// unknown). `AuthBloc` ignores the repository until that check ends, so
  /// a read landing first would move the repository and leave the bloc
  /// behind, and nothing would bring them back together. A sign-in
  /// broadcast is read again once the check has decided; for focus, the
  /// check's own read is fresh enough.
  Future<void> _rereadAfterEvent() async {
    if (_repository.currentAuthState is AuthStateUnknown) return;
    try {
      await _sharedRead();
    } on Object catch (error) {
      _log.warn(
        'Could not re-read the session; this tab keeps its current state',
        context: {'cause': error.runtimeType.toString()},
      );
    }
  }

  @override
  Future<void> onDispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _channel.close();
  }
}
