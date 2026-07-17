import 'package:logging/logging.dart';

import 'log_record_formatter.dart';
import 'log_sink.dart';

/// A [LogSink] that writes flat formatted lines through a print function —
/// the web console sink (issue #100).
///
/// `dart:developer`'s DevTools bridge is unavailable in a deployed release
/// web build (there is no VM service attached), so plain `print` → the
/// browser console is the dependable path for web. Also convenient as a
/// CI/test sink.
class PrintLogSink implements LogSink {
  /// Creates the sink. [out] defaults to `print`; tests inject a spy.
  /// [formatter] controls the line shape.
  PrintLogSink({
    void Function(String line)? out,
    LogRecordFormatter formatter = const LogRecordFormatter(),
  }) : _out = out ?? _defaultOut,
       _formatter = formatter;

  final void Function(String line) _out;
  final LogRecordFormatter _formatter;

  static void _defaultOut(String line) {
    // ignore: avoid_print
    print(line);
  }

  @override
  void emit(LogRecord record) {
    try {
      _out(_formatter.formatLine(record));
    } on Object {
      // LogSink.emit must not throw: a misbehaving formatter or out
      // callback must not crash the caller (best-effort logging).
    }
  }

  @override
  Future<void> close() async {
    // Nothing to flush.
  }
}
