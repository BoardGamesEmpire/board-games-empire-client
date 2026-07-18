import 'package:logging/logging.dart';

/// A destination for [LogRecord]s (issue #100).
///
/// Sinks are deliberately "dumb": they render and write, nothing more.
/// Level filtering (the build-mode console gate) is applied *upstream* by
/// the shell (`ShellObservability`) before [emit] is ever called, so a
/// sink never decides what to drop — keeping the build-mode policy in one
/// place and the sinks trivially testable.
///
/// The root-logger subscription and its lifecycle are owned by the shell;
/// a sink only answers two questions: how is a record rendered, and where
/// does it go. `package:logging` is process-global, so exactly one sink
/// (which may be a [CompositeLogSink]) is attached per process.
abstract interface class LogSink {
  /// Renders and writes [record].
  ///
  /// Must not throw: a logging sink that throws would turn a diagnostic
  /// into a second failure. Implementations swallow their own IO errors
  /// (a dropped log line is strictly better than a crash-in-the-crash).
  void emit(LogRecord record);

  /// Flushes and releases any held resources (e.g. a file handle).
  ///
  /// A no-op for console sinks. Awaited by `ShellObservability.reset` so
  /// tests re-initialise cleanly. In production there is no guaranteed
  /// teardown point — hot restart does not fire `dispose`, a universal
  /// Flutter constraint — so file-backed sinks must also flush as they
  /// write rather than relying on this.
  Future<void> close();
}
