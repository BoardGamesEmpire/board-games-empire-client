import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// The record is the RAM-only payload held in ShellObservability's
/// single-slot last-error notifier and handed to UncaughtErrorReporter
/// implementations. Sanitisation happens at construction — matching the
/// BreadcrumbBuffer's capture-time philosophy — so nothing downstream has
/// to remember to redact. Stack traces are kept raw (they are not
/// pattern-redacted anywhere; the privacy control is that they never
/// leave RAM until the user explicitly submits a feedback report).
void main() {
  group('UncaughtErrorRecord.capture', () {
    test('redacts email addresses in the error message at construction', () {
      final record = UncaughtErrorRecord.capture(
        Exception('login failed for john.doe@email.com'),
        StackTrace.current,
      );

      // Exact masked shape is pinned by redaction_test.dart; here we pin
      // that the record went through Redaction.redactEmailsIn.
      expect(record.message, contains('j**n.d*e@email.com'));
      expect(record.message, isNot(contains('john.doe@email.com')));
    });

    test('the message carries no bound values, and an email in the same '
        'text is still redacted', () {
      final record = UncaughtErrorRecord.capture(
        _DatabaseError(),
        StackTrace.current,
      );

      expect(record.message, isNot(contains('user-42')));
      expect(record.message, isNot(contains('Kitchen Table')));
      expect(record.message, contains('Causing statement'));
      expect(record.message, contains('j**n.d*e@email.com'));
      expect(record.message, isNot(contains('john.doe@email.com')));
    });

    test('keeps the message unchanged when no email is present', () {
      final record = UncaughtErrorRecord.capture(
        StateError('nothing sensitive here'),
        StackTrace.current,
      );

      expect(record.message, 'Bad state: nothing sensitive here');
    });

    test('records the error runtime type so crumb context and reports can '
        'name what crashed without leaking message contents', () {
      final record = UncaughtErrorRecord.capture(
        StateError('boom'),
        StackTrace.current,
      );

      expect(record.errorType, 'StateError');
    });

    test('preserves the stack trace instance untouched — the trace is the '
        'one piece FeedbackService needs verbatim', () {
      final trace = StackTrace.current;

      final record = UncaughtErrorRecord.capture(StateError('boom'), trace);

      expect(record.stackTrace, same(trace));
    });

    test('timestamp defaults to construction time', () {
      final before = DateTime.now();
      final record = UncaughtErrorRecord.capture(
        StateError('boom'),
        StackTrace.current,
      );
      final after = DateTime.now();

      expect(
        record.timestamp.isBefore(before) || record.timestamp.isAfter(after),
        isFalse,
        reason: 'timestamp must fall within the construction window',
      );
    });

    test('an injected timestamp is respected (testability seam)', () {
      final fixed = DateTime.utc(2026, 7, 7, 12);

      final record = UncaughtErrorRecord.capture(
        StateError('boom'),
        StackTrace.current,
        timestamp: fixed,
      );

      expect(record.timestamp, fixed);
    });
  });
}

/// An error whose text is a `SqliteException`'s. The email sits ahead of
/// `, parameters: ` so it is the email redaction that gets tested, not the
/// cut at the parameters.
class _DatabaseError {
  @override
  String toString() =>
      'SqliteException(2067): while executing statement, UNIQUE constraint '
      'failed for john.doe@email.com\n'
      '  Causing statement: INSERT INTO t (a) VALUES (?), '
      'parameters: user-42, Kitchen Table';
}
