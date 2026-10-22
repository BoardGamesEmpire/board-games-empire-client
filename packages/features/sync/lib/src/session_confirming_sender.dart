import 'package:interfaces/orchestration.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';

/// A [SyncOperationSender] that sends only while the session is still the
/// user the session scope belongs to (#432).
///
/// On web every tab shares one session cookie. A sign-in in another tab
/// moves it to another user under a tab still presenting the first, and an
/// op sent then is created as the other user on the server while this
/// device records it as the first. So each delivery asks the
/// [SessionIdentityGuard] first.
///
/// A refusal claims and counts nothing, and the op stays queued for a sender
/// that can send it. It comes back as the failure the same finding would be
/// from the server: [SyncFailure.sessionRejected], a 401's, when the session
/// is another user's, so a drain asks the auth layer about it; and
/// [SyncFailure.unreachable] when the guard could not ask, so an offline
/// drain does not. The inline create reads either as saved but not yet
/// sent, and a drain stops its pass on either.
///
/// Every sender of the session goes through this one — the inline create
/// today, and the web drain (#447) once it lands — so the check holds for
/// all of them without each asking. Native composes no guard, and so no
/// wrapper.
///
/// Known gap: the guard answers before [_inner] claims the entry and sends
/// it, and each step awaits. A sign-in in another tab that lands in that
/// window still sends the op as the other user. Asking again after the claim
/// would narrow the window, but not close it, since the cookie can still
/// change before the request leaves. Only the server can close it, by
/// refusing a request whose session is not the user the client meant
/// (backend#793).
class SessionConfirmingSender implements SyncOperationSender {
  const SessionConfirmingSender({
    required this._inner,
    required this._guard,
    required this._userId,
  });

  final SyncOperationSender _inner;
  final SessionIdentityGuard _guard;
  final String _userId;

  @override
  Future<SyncDelivery> deliver(String entryId, SyncOperation operation) async =>
      await _refusal() ?? await _inner.deliver(entryId, operation);

  @override
  Future<SyncDelivery> deliverEntry(SyncQueueEntry entry) async =>
      await _refusal() ?? await _inner.deliverEntry(entry);

  /// The failure to hand back instead of sending, or null to send.
  Future<SyncDelivery?> _refusal() async {
    final answer = await _guard.confirm(_userId);
    return switch (answer) {
      SessionConfirmation.confirmed => null,
      SessionConfirmation.notThisUser => SyncFailed(
        SyncFailure.sessionRejected,
        SessionNotConfirmedException(answer),
      ),
      SessionConfirmation.unanswered => SyncFailed(
        SyncFailure.unreachable,
        SessionNotConfirmedException(answer),
      ),
    };
  }
}

/// What a [SessionConfirmingSender] refusal carries as its error (#432).
final class SessionNotConfirmedException implements Exception {
  const SessionNotConfirmedException(this.answer);

  /// What the guard said instead of confirming.
  final SessionConfirmation answer;

  @override
  String toString() =>
      'SessionNotConfirmedException: the session could not be confirmed as '
      'this scope\'s user (${answer.name})';
}
