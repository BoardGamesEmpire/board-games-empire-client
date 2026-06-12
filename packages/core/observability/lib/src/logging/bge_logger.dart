import 'package:logging/logging.dart';

import 'bge_log_level.dart';
import 'context_log_message.dart';

/// Thin wrapper around `package:logging`'s [Logger] exposing the BGE
/// five-level scheme (issue #8).
///
/// ## Naming
///
/// Logger names are hierarchical and align with package structure:
/// `bge.storage.sync_queue`, `bge.network.dio`, `bge.auth.bloc`, etc.
/// `package:logging` canonicalises by name, so two `BgeLogger`s with the
/// same name share the same underlying logger.
///
/// ## Configuration
///
/// Level filtering and sink wiring are app-shell concerns: each app's
/// `main.dart` sets `Logger.root.level` and attaches its platform sink
/// (Logcat on Android, stdout/rotating file on macOS, console on web) to
/// `Logger.root.onRecord`. This package only emits.
///
/// ## Context
///
/// Every method takes an optional `context` map. Non-empty contexts are
/// wrapped in [ContextLogMessage] so structured consumers (the
/// BreadcrumbBuffer, future JSON sinks) can read them off
/// `LogRecord.object`, while `LogRecord.message` stays the plain text.
/// Context values are NOT redacted here — see [ContextLogMessage] for the
/// capture-time sanitisation rationale.
class BgeLogger {
  /// Creates (or retrieves) the logger named [name].
  BgeLogger(String name) : _logger = Logger(name);

  final Logger _logger;

  /// The hierarchical logger name.
  String get name => _logger.fullName;

  /// Logs at [BgeLogLevel.verbose] (≈ FINEST). High-volume tracing.
  void verbose(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) => _log(BgeLogLevel.verbose, message, error, stackTrace, context);

  /// Logs at [BgeLogLevel.debug] (≈ FINE). Developer diagnostics.
  void debug(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) => _log(BgeLogLevel.debug, message, error, stackTrace, context);

  /// Logs at [BgeLogLevel.info]. Notable application events.
  void info(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) => _log(BgeLogLevel.info, message, error, stackTrace, context);

  /// Logs at [BgeLogLevel.warn] (= WARNING). Recoverable problems.
  void warn(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) => _log(BgeLogLevel.warn, message, error, stackTrace, context);

  /// Logs at [BgeLogLevel.error] (≈ SEVERE). Failures needing attention.
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) => _log(BgeLogLevel.error, message, error, stackTrace, context);

  void _log(
    BgeLogLevel level,
    String message,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  ) {
    final Object payload = (context == null || context.isEmpty)
        ? message
        : ContextLogMessage(message, context);
    _logger.log(level.level, payload, error, stackTrace);
  }
}
