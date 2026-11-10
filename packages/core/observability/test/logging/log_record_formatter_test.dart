import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  group('LogRecordFormatter', () {
    const formatter = LogRecordFormatter(includeTimestamp: false);

    test('renders level tag, logger, and message (BGE level names)', () {
      final line = formatter.formatLine(
        LogRecord(Level.WARNING, 'disk almost full', 'bge.storage'),
      );
      expect(line, '[WARN] bge.storage: disk almost full');
    });

    test('collapses SEVERE onto the ERROR tag', () {
      final line = formatter.formatLine(
        LogRecord(Level.SEVERE, 'boom', 'bge.x'),
      );
      expect(line, startsWith('[ERROR] '));
    });

    test('appends compact JSON context read off ContextLogMessage', () {
      const payload = ContextLogMessage('op failed', {'code': 503});
      final line = formatter.formatLine(
        LogRecord(
          Level.INFO,
          payload.toString(),
          'bge.net',
          null,
          null,
          null,
          payload,
        ),
      );
      expect(line, '[INFO] bge.net: op failed {"code":503}');
    });

    test('omits an empty context entirely (no trailing {})', () {
      const payload = ContextLogMessage('plain', <String, dynamic>{});
      final line = formatter.formatLine(
        LogRecord(
          Level.INFO,
          payload.toString(),
          'bge.net',
          null,
          null,
          null,
          payload,
        ),
      );
      expect(line, '[INFO] bge.net: plain');
    });

    test('appends the error after a pipe separator', () {
      final line = formatter.formatLine(
        LogRecord(Level.SEVERE, 'crashed', 'bge.x', StateError('nope')),
      );
      expect(line, contains(' | '));
      expect(line, endsWith('nope'));
    });

    test("a database error's bound values are not written", () {
      final line = formatter.formatLine(
        LogRecord(Level.SEVERE, 'crashed', 'bge.x', _DatabaseError()),
      );
      expect(line, isNot(contains('user-42')));
      expect(line, isNot(contains('Kitchen Table')));
      expect(line, contains('Causing statement'));
    });

    test('prefixes a UTC ISO-8601 timestamp (Z-suffixed) when enabled', () {
      const withTime = LogRecordFormatter();
      final line = withTime.formatLine(LogRecord(Level.INFO, 'hi', 'bge.x'));
      expect(line, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T')));
      // UTC marker present so persisted timestamps are unambiguous.
      expect(line.split(' ').first, endsWith('Z'));
    });

    group('contextOf', () {
      test('reads a ContextLogMessage payload', () {
        const payload = ContextLogMessage('m', {'a': 1});
        final record = LogRecord(
          Level.INFO,
          payload.toString(),
          'n',
          null,
          null,
          null,
          payload,
        );
        expect(LogRecordFormatter.contextOf(record), {'a': 1});
      });

      test('reads a raw Map payload', () {
        final record = LogRecord(Level.INFO, 'm', 'n', null, null, null, {
          'a': 1,
        });
        expect(LogRecordFormatter.contextOf(record), {'a': 1});
      });

      test('returns null for a plain string message', () {
        final record = LogRecord(Level.INFO, 'm', 'n');
        expect(LogRecordFormatter.contextOf(record), isNull);
      });
    });

    group('encodeContext', () {
      test('null for null or empty', () {
        expect(LogRecordFormatter.encodeContext(null), isNull);
        expect(LogRecordFormatter.encodeContext(const {}), isNull);
      });

      test('compact json for a populated map', () {
        expect(LogRecordFormatter.encodeContext(const {'k': 'v'}), '{"k":"v"}');
      });

      test('degrades non-encodable values to toString', () {
        final encoded = LogRecordFormatter.encodeContext({
          'when': _Unencodable(),
        });
        expect(encoded, contains('unencodable'));
      });
    });
  });
}

/// An error whose text is a `SqliteException`'s, bound values and all.
class _DatabaseError {
  @override
  String toString() =>
      'SqliteException(2067): while executing statement, UNIQUE constraint failed\n'
      '  Causing statement: INSERT INTO t (a) VALUES (?), parameters: user-42, Kitchen Table';
}

class _Unencodable {
  @override
  String toString() => 'unencodable';
}
