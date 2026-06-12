/// Structured log payload: a plain message plus a context map.
///
/// [BgeLogger] wraps `(message, context)` pairs in this class before
/// handing them to `package:logging`, which stores non-String payloads on
/// `LogRecord.object` while deriving `LogRecord.message` from [toString].
///
/// [toString] deliberately returns [text] alone: handlers that only print
/// `record.message` (Logcat bridges, stdout formatters, test matchers)
/// behave exactly as if a plain String had been logged, while structured
/// consumers — the BreadcrumbBuffer's sanitised-context capture, future
/// JSON sinks — read [context] off `record.object`.
final class ContextLogMessage {
  const ContextLogMessage(this.text, this.context);

  /// The human-readable log line.
  final String text;

  /// Structured key/value context attached to the line.
  ///
  /// NOT redacted at this layer — sanitisation happens at capture time
  /// (BreadcrumbBuffer) so that local dev consoles keep full fidelity
  /// while anything buffered for potential submission is scrubbed.
  final Map<String, dynamic> context;

  @override
  String toString() => text;
}
