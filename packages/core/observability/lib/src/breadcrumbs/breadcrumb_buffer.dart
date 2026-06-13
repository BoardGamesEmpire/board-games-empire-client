import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';

import '../logging/bge_log_level.dart';
import '../logging/context_log_message.dart';
import '../redaction/redaction.dart';
import 'breadcrumb.dart';

/// Bounded ring buffer of sanitised [Breadcrumb]s captured from
/// `Logger.root` (issue #8).
///
/// When a crash or bug report is assembled, [snapshot] supplies the last
/// [capacity] log records as context. Sanitisation happens at capture —
/// not at emit — so local dev consoles keep full fidelity while anything
/// that could leave the device is scrubbed:
///
/// - Messages run through [Redaction.redactEmailsIn].
/// - Context maps (from [ContextLogMessage] payloads, or a raw `Map`
///   logged directly) run through [Redaction.redactJsonFields] against
///   [redactedContextFields].
/// - Stack traces are NOT buffered: `LogRecord.error` / `stackTrace` stay
///   on the live record for console handlers. Error text reaches the
///   buffer only if the caller put it in the message, where the email
///   masking applies.
///
/// Capture is level-gated by `Logger.root.level` like any other root
/// listener — records filtered out by the root level never reach the
/// buffer.
class BreadcrumbBuffer {
  /// Creates a buffer holding at most [capacity] crumbs.
  ///
  /// [redactedContextFields] REPLACES (not extends) the defaults when
  /// supplied; callers wanting both spread them:
  /// `{...BreadcrumbBuffer.defaultRedactedContextFields, 'extra'}`.
  BreadcrumbBuffer({
    int capacity = defaultCapacity,
    Set<String> redactedContextFields = defaultRedactedContextFields,
  }) : assert(capacity > 0, 'capacity must be positive'),
       _capacity = capacity,
       _redactedContextFields = Set.unmodifiable(redactedContextFields);

  /// Default ring size per issue #8.
  static const int defaultCapacity = 100;

  /// Context keys scrubbed by default. Key-based (exact, case-sensitive)
  /// because context values aren't pattern-scanned — only messages are.
  static const Set<String> defaultRedactedContextFields = {
    'accessToken',
    'apiKey',
    'authorization',
    'cookie',
    'email',
    'password',
    'refreshToken',
    'secret',
    'sessionToken',
    'token',
  };

  final int _capacity;
  final Set<String> _redactedContextFields;
  final Queue<Breadcrumb> _buffer = Queue<Breadcrumb>();
  StreamSubscription<LogRecord>? _subscription;

  /// Maximum number of crumbs retained.
  int get capacity => _capacity;

  /// Current number of buffered crumbs.
  int get length => _buffer.length;

  /// Whether the buffer is currently subscribed to `Logger.root`.
  bool get isAttached => _subscription != null;

  /// Starts capturing from `Logger.root.onRecord`. Idempotent — calling
  /// while attached is a no-op (no duplicate subscription).
  void attach() {
    if (_subscription != null) return;
    _subscription = Logger.root.onRecord.listen(add);
  }

  /// Stops capturing. Buffered crumbs are retained; call [clear] to drop
  /// them.
  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Sanitises [record] into a [Breadcrumb] and appends it, evicting the
  /// oldest entries beyond [capacity]. Public so tests and synthetic
  /// capture paths can feed records without going through `Logger.root`.
  void add(LogRecord record) {
    _buffer.add(_toBreadcrumb(record));
    while (_buffer.length > _capacity) {
      _buffer.removeFirst();
    }
  }

  /// A point-in-time, unmodifiable copy of the buffer, oldest first.
  List<Breadcrumb> snapshot() => List.unmodifiable(_buffer);

  /// Drops all buffered crumbs without detaching.
  void clear() => _buffer.clear();

  /// Substituted for [Breadcrumb.message] when a raw `Map` is the log
  /// payload — `record.message` derives from `map.toString()`, which
  /// only the email pattern masks. The structured map is still
  /// captured (and redacted) in [Breadcrumb.sanitizedContext].
  static const String rawMapMessagePlaceholder = '<context map>';

  Breadcrumb _toBreadcrumb(LogRecord record) {
    final object = record.object;
    Map<String, dynamic>? context;
    var rawMapPayload = false;
    if (object is ContextLogMessage) {
      context = object.context;
    } else if (object is Map<String, dynamic>) {
      context = object;
      rawMapPayload = true;
    } else if (object is Map) {
      context = object.map((key, value) => MapEntry(key.toString(), value));
      rawMapPayload = true;
    }
    return Breadcrumb(
      timestamp: record.time,
      level: BgeLogLevel.fromLevel(record.level),
      loggerName: record.loggerName,
      message: rawMapPayload
          ? rawMapMessagePlaceholder
          : Redaction.redactEmailsIn(record.message),
      sanitizedContext: context == null
          ? null
          : Redaction.redactJsonFields(context, _redactedContextFields),
    );
  }
}
