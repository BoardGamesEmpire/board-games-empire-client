import 'package:json_annotation/json_annotation.dart';
import 'package:logging/logging.dart';

/// The five-level BGE logging scheme, collapsed from `package:logging`'s
/// java.util.logging-style defaults (issue #8 design):
///
/// | BGE       | package:logging |
/// |-----------|-----------------|
/// | [verbose] | FINEST (300)    |
/// | [debug]   | FINE (500)      |
/// | [info]    | INFO (800)      |
/// | [warn]    | WARNING (900)   |
/// | [error]   | SEVERE (1000)   |
///
/// Mapping back from arbitrary [Level]s (including FINER, CONFIG, SHOUT,
/// and custom values) is threshold-based via [fromLevel]: a record maps to
/// the highest BGE level whose underlying value it meets.
///
/// The wire form (used when a [Level] is persisted inside a Breadcrumb) is
/// the camelCase enum name. Unlike the feedback enums, this is a
/// client-internal shape with no server counterpart, so camelCase rather
/// than the backend's PascalCase convention. [fromWire] is strict: these
/// strings are client-authored, so an unrecognised value indicates
/// corruption and throws [StateError] rather than coercing.
enum BgeLogLevel {
  @JsonValue('verbose')
  verbose,
  @JsonValue('debug')
  debug,
  @JsonValue('info')
  info,
  @JsonValue('warn')
  warn,
  @JsonValue('error')
  error;

  /// The `package:logging` [Level] this BGE level emits at.
  Level get level => switch (this) {
    verbose => Level.FINEST,
    debug => Level.FINE,
    info => Level.INFO,
    warn => Level.WARNING,
    error => Level.SEVERE,
  };

  /// Collapses any `package:logging` [Level] onto the five-level scheme
  /// by numeric threshold.
  static BgeLogLevel fromLevel(Level level) {
    if (level.value >= Level.SEVERE.value) return error;
    if (level.value >= Level.WARNING.value) return warn;
    if (level.value >= Level.INFO.value) return info;
    if (level.value >= Level.FINE.value) return debug;
    return verbose;
  }

  /// Parses a wire-format string. Strict: unknown values throw
  /// [StateError] (see class doc).
  static BgeLogLevel fromWire(String value) => switch (value) {
    'verbose' => verbose,
    'debug' => debug,
    'info' => info,
    'warn' => warn,
    'error' => error,
    _ => throw StateError('Unknown BgeLogLevel wire value: $value'),
  };

  /// The wire-format string for this level. MUST agree with the
  /// `@JsonValue` annotations; a test in `bge_log_level_test.dart`
  /// guards against drift.
  String toWire() => switch (this) {
    verbose => 'verbose',
    debug => 'debug',
    info => 'info',
    warn => 'warn',
    error => 'error',
  };
}
