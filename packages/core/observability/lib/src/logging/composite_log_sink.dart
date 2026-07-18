import 'package:logging/logging.dart';

import 'log_sink.dart';

/// Fans each record out to several [LogSink]s (issue #100).
///
/// Desktop composes console + rotating file through this; single-sink
/// platforms (mobile, web) never need it. [emit] tolerates a throwing
/// child so one misbehaving sink cannot starve the others or surface an
/// error to the caller; [close] awaits every child even if some fail.
class CompositeLogSink implements LogSink {
  /// Wraps [sinks] (defensively copied, order preserved).
  CompositeLogSink(List<LogSink> sinks) : _sinks = List.unmodifiable(sinks);

  final List<LogSink> _sinks;

  @override
  void emit(LogRecord record) {
    for (final sink in _sinks) {
      try {
        sink.emit(record);
      } on Object {
        // A misbehaving sink must not block the others or reach the
        // caller — logging is best-effort by contract (see LogSink.emit).
      }
    }
  }

  @override
  Future<void> close() async {
    for (final sink in _sinks) {
      try {
        await sink.close();
      } on Object {
        // Best-effort: close the remaining sinks regardless.
      }
    }
  }
}
