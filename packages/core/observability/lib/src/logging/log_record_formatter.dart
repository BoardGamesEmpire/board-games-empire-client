import 'dart:convert';

import 'package:logging/logging.dart';

import 'bge_log_level.dart';
import 'context_log_message.dart';

/// Renders a [LogRecord] into a single flat line for text sinks — the
/// rotating file sink and the web `print` console (issue #100).
///
/// One line per record so logs scan vertically: `<time> [<LEVEL>]
/// <logger>: <message>` optionally followed by ` <compact-json-context>`
/// and, when an error rode along, ` | <error>`. The level tag is the BGE
/// five-level name (`VERBOSE`/`DEBUG`/`INFO`/`WARN`/`ERROR`), collapsed
/// from the underlying `package:logging` [Level] via [BgeLogLevel], not
/// the raw `FINE`/`SEVERE` names.
///
/// The context is read from the record's structured payload
/// ([ContextLogMessage] or a raw `Map`), NOT from `record.message` —
/// `ContextLogMessage.toString()` deliberately returns the message text
/// alone, so the map has to be pulled off `record.object` and encoded
/// separately.
///
/// No redaction happens here: per the #8 split, dev consoles keep full
/// fidelity and context producers are responsible for never putting
/// secrets in a message or context (only the BreadcrumbBuffer's
/// capture-time scrub touches submittable data).
class LogRecordFormatter {
  const LogRecordFormatter({this.includeTimestamp = true});

  /// Whether to prefix the ISO-8601 record time. Off for deterministic
  /// test matching; on for real sinks.
  final bool includeTimestamp;

  /// The single-line rendering of [record].
  String formatLine(LogRecord record) {
    final level = BgeLogLevel.fromLevel(record.level).toWire().toUpperCase();
    final buffer = StringBuffer();
    if (includeTimestamp) {
      // UTC so persisted file logs (and the web console) are unambiguous
      // across machines/timezones — a local DateTime's toIso8601String
      // carries no offset marker.
      buffer
        ..write(record.time.toUtc().toIso8601String())
        ..write(' ');
    }
    buffer
      ..write('[')
      ..write(level)
      ..write('] ')
      ..write(record.loggerName)
      ..write(': ')
      ..write(record.message);

    final encoded = encodeContext(contextOf(record));
    if (encoded != null) {
      buffer
        ..write(' ')
        ..write(encoded);
    }
    if (record.error != null) {
      buffer
        ..write(' | ')
        ..write(record.error);
    }
    return buffer.toString();
  }

  /// Pulls the structured context map off a record's payload, or null when
  /// the record carried none.
  ///
  /// [BgeLogger] wraps `(message, context)` pairs in [ContextLogMessage];
  /// a raw `Map` logged directly is also honoured. Any other payload
  /// (including a plain `String`, where `record.object` is null) yields
  /// null.
  static Map<String, dynamic>? contextOf(LogRecord record) {
    final object = record.object;
    if (object is ContextLogMessage) return object.context;
    if (object is Map<String, dynamic>) return object;
    if (object is Map) {
      return object.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  /// Compact single-line JSON for [context], or null when it is null or
  /// empty (an empty `{}` is dropped to keep the console clean).
  ///
  /// Values `jsonEncode` cannot serialise degrade to their `toString()`
  /// rather than throwing — a formatter must never be the thing that
  /// crashes a log call.
  static String? encodeContext(Map<String, dynamic>? context) {
    if (context == null || context.isEmpty) return null;
    try {
      return jsonEncode(context, toEncodable: (value) => value.toString());
    } on Object {
      return context.toString();
    }
  }
}
