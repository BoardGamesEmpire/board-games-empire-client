import 'package:models/domain.dart';

/// What the signed-in user may do on the server they are connected to, as the
/// server answers it (#456, #274).
///
/// The client shows a control only when the server says the caller may use
/// it, and hides it while the answer is unknown. It never re-checks a
/// condition itself where the answer is [AccessExtent.some].
abstract interface class CallerAccessRepository {
  /// The latest answer, [CallerAccess.unknown] until one has been kept.
  ///
  /// Replaced only by an answer that differs from it, the one [changes]
  /// emits: an equal answer leaves this the same instance, so a caller can
  /// tell by identity whether anything has landed since it read this.
  CallerAccess get current;

  /// Each answer that differs from the last.
  ///
  /// A broadcast stream. Every call returns the same instance, so a
  /// `StreamBuilder` does not resubscribe on rebuild.
  Stream<CallerAccess> get changes;

  /// Asks the server again.
  ///
  /// Never throws: a failed ask keeps the last answer. A call made while an
  /// ask is in flight is answered by an ask sent after it, since the one in
  /// flight may predate the caller's reason to ask.
  Future<void> refresh();
}
