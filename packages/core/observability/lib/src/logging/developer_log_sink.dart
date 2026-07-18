import 'dart:developer' as developer;

import 'package:logging/logging.dart';

import 'log_record_formatter.dart';
import 'log_sink.dart';

/// The `dart:developer` [developer.log] signature, extracted so tests can
/// inject a spy in place of the real (side-effecting, hard-to-capture)
/// call.
typedef DeveloperLogFn =
    void Function(
      String message, {
      DateTime? time,
      int level,
      String name,
      Object? error,
      StackTrace? stackTrace,
    });

/// A [LogSink] that forwards records to `dart:developer`'s `log()` — the
/// native console sink (issue #100).
///
/// `developer.log` surfaces in the Flutter DevTools logging view and, on
/// Android, bridges to Logcat, so this one sink covers "Logcat on mobile"
/// and "DevTools console on desktop" at once.
///
/// Context handling follows the #100 rule, exploiting that `developer.log`
/// has a structured `error` slot but no `context` slot:
/// - **error present** → the real error goes in the `error` slot and the
///   compact context is appended to the message (so nothing is lost);
/// - **no error, context present** → the context *map itself* goes in the
///   `error` slot, so it renders as an inspectable object in DevTools
///   rather than a flattened string;
/// - **empty/no context** → neither is emitted.
class DeveloperLogSink implements LogSink {
  /// Creates the sink. [logFn] defaults to `dart:developer`'s `log`;
  /// tests inject a spy.
  DeveloperLogSink({DeveloperLogFn? logFn}) : _log = logFn ?? _defaultLog;

  final DeveloperLogFn _log;

  static void _defaultLog(
    String message, {
    DateTime? time,
    int level = 0,
    String name = '',
    Object? error,
    StackTrace? stackTrace,
  }) => developer.log(
    message,
    time: time,
    level: level,
    name: name,
    error: error,
    stackTrace: stackTrace,
  );

  @override
  void emit(LogRecord record) {
    try {
      final context = LogRecordFormatter.contextOf(record);
      final hasContext = context != null && context.isNotEmpty;
      final hasError = record.error != null;
      final encoded = LogRecordFormatter.encodeContext(context);

      final message = (hasError && encoded != null)
          ? '${record.message} $encoded'
          : record.message;
      // Error slot: a real exception wins it; otherwise the raw context map
      // rides there so DevTools can render it structurally.
      final Object? errorArg = hasError
          ? record.error
          : (hasContext ? context : null);

      _log(
        message,
        time: record.time,
        level: record.level.value,
        name: record.loggerName,
        error: errorArg,
        stackTrace: record.stackTrace,
      );
    } on Object {
      // LogSink.emit must not throw: a misbehaving formatter, context
      // encode, or logFn must not crash the caller (best-effort logging).
    }
  }

  @override
  Future<void> close() async {
    // Nothing to flush: developer.log owns its own delivery.
  }
}
