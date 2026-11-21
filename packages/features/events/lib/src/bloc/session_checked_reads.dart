import 'package:observability/observability.dart';

/// The sequencing a bloc that reads an event's rows online shares (#519): one
/// read out at a time, and the latest request while it is out re-run once
/// after, by [run]. It also holds the flags a retry's narration and a close
/// need ([retrying], [stillRefreshing], [closing]) and the session check
/// ([confirmed]).
///
/// The bloc decides where to check. It asks [confirmed] before each read or
/// send and again before it uses an answer (#432), a write's as well as a
/// read's, and it keeps what each read emits.
///
/// A null `confirmSession`, as on native, is always yes. A no, or a throw, is
/// a no here, logged saying what stopped.
final class SessionCheckedReads {
  SessionCheckedReads({
    required this._confirmSession,
    required this._logger,
  });

  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// Set once the bloc's `close` starts. An answer can land after it, and
  /// the bloc emits nothing then.
  bool closing = false;

  /// Whether a retry joined the reads running now, which the bloc's state
  /// says until they end. Set by the bloc as the retry arrives; cleared as
  /// the reads end.
  bool retrying = false;

  bool _reading = false;
  String? _readAgain;

  /// Whether a retry is still under way as a read ends: one joined the
  /// reads, and another is to run after this one.
  bool get stillRefreshing => retrying && _readAgain != null;

  /// Reads the event [eventId] with [readOnce], then again for the latest
  /// request that came in meanwhile, once each run. While a read is out, this
  /// marks one more and returns. [readOnce] never throws.
  Future<void> run(
    String eventId,
    Future<void> Function(String eventId) readOnce,
  ) async {
    if (_reading) {
      _readAgain = eventId;
      return;
    }
    _reading = true;
    try {
      String? next = eventId;
      while (next != null && !closing) {
        _readAgain = null;
        await readOnce(next);
        next = _readAgain;
      }
    } finally {
      _readAgain = null;
      _reading = false;
      retrying = false;
    }
  }

  /// Whether the session is still this viewer's: `confirmSession` said yes,
  /// or there is none to ask. A no is logged, as is a throw, each saying
  /// what [stopped].
  Future<bool> confirmed(String stopped) async {
    final confirm = _confirmSession;
    if (confirm == null) return true;

    final bool confirmed;
    try {
      confirmed = await confirm();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        '$stopped: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
    if (!confirmed) {
      _logger.info(
        "$stopped: the session could not be confirmed as this user's",
      );
    }
    return confirmed;
  }
}
