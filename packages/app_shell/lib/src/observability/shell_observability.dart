import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';

import 'uncaught_error_record.dart';

/// Process-wide observability wiring owned by the shell.
///
/// `package:logging` is inherently global (loggers propagate to
/// [Logger.root]), so the shell owns the single [BreadcrumbBuffer] attached
/// to it. [runBgeApp] initializes this before anything else logs, ensuring
/// the ring buffer has history from the very first bootstrap step — which
/// is exactly what a feedback report about "the app won't start" needs.
///
/// The feedback UI ("ask each time" in alpha) consumes [breadcrumbs] and
/// [lastUncaughtError] via `FeedbackService` when that wiring lands;
/// `installGlobalErrorHooks` (issue #34) feeds [lastUncaughtError] through
/// [recordUncaughtError].
///
/// ## Log sink + level filtering (issue #100)
///
/// [initialize] accepts a platform [LogSink] (see
/// `PlatformBootstrap.createLogSink`) and a [BgeLogLevel] `consoleThreshold`.
/// The root logger stays pinned to [Level.ALL] so the breadcrumb ring sees
/// every record — its bounded capacity, NOT the root level, is the
/// retention policy. The build-mode gate lives on the **sink path** here
/// instead: a record is forwarded to the sink only when it meets the
/// threshold (`warn+` in release, everything in debug/profile). So a
/// release build shows warnings/errors on the console yet still carries a
/// full-fidelity breadcrumb trail into any feedback report.
abstract final class ShellObservability {
  static BreadcrumbBuffer? _buffer;
  static ValueNotifier<UncaughtErrorRecord?>? _lastUncaughtError;
  static StreamSubscription<LogRecord>? _sinkSubscription;
  static LogSink? _sink;
  static Level? _previousRootLevel;

  /// The process-wide breadcrumb ring buffer. Throws if [initialize] has
  /// not run yet — that ordering bug should fail fast, not report empty
  /// breadcrumbs.
  static BreadcrumbBuffer get breadcrumbs =>
      _require(_buffer, 'breadcrumbs are read');

  /// Fail-fast accessor shared by [breadcrumbs] and the last-error slot so
  /// the two "initialize() must run first" messages can't drift apart.
  static T _require<T>(T? value, String usage) {
    if (value == null) {
      throw StateError(
        'ShellObservability.initialize() must run before $usage; '
        'runBgeApp does this first.',
      );
    }
    return value;
  }

  /// Single-slot, RAM-only record of the last uncaught error (issue #34).
  ///
  /// Stack traces stay **out** of the [BreadcrumbBuffer] by design (the
  /// backend DTO has a dedicated `stackTrace` field, traces aren't
  /// pattern-redacted, and the 100-slot ring must stay small); this slot
  /// is where the last crash's full detail lives until the user submits —
  /// or declines — a feedback report. Exposed as a [ValueListenable] so
  /// the feedback prompt can react to a crash landing instead of polling.
  ///
  /// Throws before [initialize] — same fail-fast contract as
  /// [breadcrumbs].
  static ValueListenable<UncaughtErrorRecord?> get lastUncaughtError =>
      _lastUncaughtErrorOrThrow;

  static ValueNotifier<UncaughtErrorRecord?> get _lastUncaughtErrorOrThrow =>
      _require(_lastUncaughtError, 'lastUncaughtError is used');

  static bool get isInitialized => _buffer != null;

  /// Publishes [record] as the last uncaught error, replacing any
  /// previous record (single slot — most recent crash wins) and notifying
  /// listeners.
  ///
  /// Throws before [initialize]: silently dropping a crash would lose
  /// exactly the data a feedback report needs, so the ordering bug fails
  /// fast instead. (`installGlobalErrorHooks` additionally guards its
  /// capture path, so a mis-ordered production install degrades to a
  /// warn-level log rather than a secondary crash.)
  static void recordUncaughtError(UncaughtErrorRecord record) {
    _lastUncaughtErrorOrThrow.value = record;
  }

  /// Empties the last-error slot, notifying listeners. Called after a
  /// feedback report is submitted, or when the user declines to send one.
  ///
  /// Safe to call before [initialize] or after [reset] — clearing a slot
  /// that does not exist is harmless by definition, unlike recording,
  /// where dropping data silently would matter.
  static void clearUncaughtError() {
    _lastUncaughtError?.value = null;
  }

  /// Attaches breadcrumb capture and, when a [sink] is supplied, the
  /// process console/file sink. Idempotent.
  ///
  /// Opens [Logger.root] to [Level.ALL] so verbose/debug records reach the
  /// ring buffer (its bounded capacity is the retention policy; the root
  /// level must not silently drop diagnostics before capture). The
  /// build-mode gate is applied on the sink path, not the root level: a
  /// record reaches [sink] only when it meets [consoleThreshold]
  /// (`BgeLogLevel.warn` in release, `BgeLogLevel.verbose` in
  /// debug/profile — see `runBgeApp`). With no [sink] (most unit tests)
  /// only breadcrumb capture is wired.
  static void initialize({
    BreadcrumbBuffer? buffer,
    LogSink? sink,
    BgeLogLevel consoleThreshold = BgeLogLevel.verbose,
  }) {
    if (_buffer != null) return;
    _previousRootLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    _buffer = (buffer ?? BreadcrumbBuffer())..attach();
    _lastUncaughtError = ValueNotifier<UncaughtErrorRecord?>(null);
    if (sink != null) {
      _sink = sink;
      final threshold = consoleThreshold.level;
      _sinkSubscription = Logger.root.onRecord.listen((record) {
        if (record.level >= threshold) {
          sink.emit(record);
        }
      });
    }
  }

  /// Detaches and clears all wiring so tests can re-initialize cleanly,
  /// including restoring [Logger.root]'s level to whatever it was before
  /// [initialize] raised it — otherwise the `Level.ALL` override would leak
  /// across tests and into embedding apps. Cancels the sink subscription
  /// and closes the sink (flushing a file sink), and disposes the
  /// last-error notifier so recorded crash state cannot leak either.
  @visibleForTesting
  static Future<void> reset() async {
    await _buffer?.detach();
    _buffer = null;
    _lastUncaughtError?.dispose();
    _lastUncaughtError = null;
    await _sinkSubscription?.cancel();
    _sinkSubscription = null;
    await _sink?.close();
    _sink = null;
    if (_previousRootLevel != null) {
      Logger.root.level = _previousRootLevel;
      _previousRootLevel = null;
    }
  }
}
