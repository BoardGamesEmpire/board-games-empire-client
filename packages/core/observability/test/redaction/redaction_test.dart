import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// A `SqliteException`'s text as drift surfaces it: the statement, then the
/// bound values after `, parameters: `.
const _sqlite =
    'SqliteException(2067): while executing statement, UNIQUE constraint failed\n'
    '  Causing statement: INSERT INTO t (a) VALUES (?), parameters: user-42, Kitchen Table';

/// What drift's isolate channel throws for a statement sent after the
/// connection closed: no `Causing statement`, and the values follow `with`.
const _closed =
    'Bad state: Tried to send Request (id = 3): StatementMethod.insert: '
    'INSERT INTO t (a, b) VALUES (?, ?) with [user-42, Kitchen Table] over '
    'isolate channel, but the connection was closed!';

void main() {
  group('Redaction.redactName', () {
    test('empty string stays empty', () {
      expect(Redaction.redactName(''), '');
    });

    test('1-char name is fully masked', () {
      expect(Redaction.redactName('X'), '*');
    });

    test('2-char name is fully masked', () {
      expect(Redaction.redactName('Al'), '**');
    });

    test('3-char name keeps first and last char', () {
      expect(Redaction.redactName('Bob'), 'B*b');
    });

    test('4-char name keeps first and last char', () {
      expect(Redaction.redactName('John'), 'J**n');
    });

    test('mask length matches input length', () {
      expect(Redaction.redactName('Alexander').length, 'Alexander'.length);
    });
  });

  group('Redaction.redactEmail', () {
    test('redacts each dot-separated local segment, preserves domain', () {
      expect(Redaction.redactEmail('john.doe@email.com'), 'j**n.d*e@email.com');
    });

    test('single-segment local part', () {
      expect(Redaction.redactEmail('alice@example.com'), 'a***e@example.com');
    });

    test('1-char local part is fully masked', () {
      expect(Redaction.redactEmail('j@gmail.com'), '*@gmail.com');
    });

    test('string without @ is treated as a name', () {
      expect(Redaction.redactEmail('bare'), 'b**e');
    });

    test('consecutive dots preserve structural shape', () {
      expect(Redaction.redactEmail('a..b@x.com'), '*..*@x.com');
    });
  });

  group('Redaction.redactEmailsIn', () {
    test('masks an email embedded in free text', () {
      expect(
        Redaction.redactEmailsIn('sign-in failed for john.doe@email.com today'),
        'sign-in failed for j**n.d*e@email.com today',
      );
    });

    test('masks multiple emails independently', () {
      expect(
        Redaction.redactEmailsIn('from alice@example.com to bob.r@x.io'),
        'from a***e@example.com to b*b.*@x.io',
      );
    });

    test('text without emails is returned unchanged', () {
      const text = 'no addresses here, just words';
      expect(Redaction.redactEmailsIn(text), same(text));
    });
  });

  group('Redaction.stripBoundValues', () {
    test('removes the parameters and keeps the statement', () {
      expect(
        Redaction.stripBoundValues(_sqlite),
        'SqliteException(2067): while executing statement, UNIQUE constraint failed\n'
        '  Causing statement: INSERT INTO t (a) VALUES (?), parameters: <redacted>',
      );
    });

    test('removes every set when a wrapper holds two errors', () {
      const twice =
          'Bad state: rollback failed. Cause: $_sqlite\nWhile rolling back: $_sqlite';
      final out = Redaction.stripBoundValues(twice);
      expect(out, isNot(contains('user-42')));
      expect(out, isNot(contains('Kitchen Table')));
    });

    test('removes what a wrapper appends after the parameters', () {
      final out = Redaction.stripBoundValues('$_sqlite\nwrapped by: tail-42');
      expect(out, isNot(contains('tail-42')));
    });

    test(
      'removes the values from a request sent after the connection closed',
      () {
        expect(
          Redaction.stripBoundValues(_closed),
          'Bad state: Tried to send Request (id = 3): StatementMethod.insert: '
          'INSERT INTO t (a, b) VALUES (?, ?) with <redacted> over isolate '
          'channel, but the connection was closed!',
        );
      },
    );

    test(
      'removes everything after the values of a closed-connection request',
      () {
        final out = Redaction.stripBoundValues('$_closed\nwrapped by: tail-42');
        expect(out, isNot(contains('tail-42')));
        expect(out, isNot(contains('user-42')));
      },
    );

    test('leaves a closed-connection request that bound nothing alone', () {
      const unbound =
          'Bad state: Tried to send Request (id = 4): '
          'StatementMethod.custom: SELECT 1 with [] over isolate channel, but '
          'the connection was closed!';
      expect(Redaction.stripBoundValues(unbound), same(unbound));
    });

    test('an empty values list does not hide a later one', () {
      const unbound =
          'Bad state: Tried to send Request (id = 4): '
          'StatementMethod.custom: SELECT 1 with [] over isolate channel, but '
          'the connection was closed!';
      final out = Redaction.stripBoundValues('$unbound\nthen: $_closed');
      expect(out, isNot(contains('user-42')));
      expect(out, isNot(contains('Kitchen Table')));
    });

    test('removes values whose first one starts with a closing bracket', () {
      const bracketed =
          'Bad state: Tried to send Request (id = 6): '
          'StatementMethod.insert: INSERT INTO t (a, b) VALUES (?, ?) with '
          '[]Kitchen Table, user-42] over isolate channel, but the connection '
          'was closed!';
      final out = Redaction.stripBoundValues(bracketed);
      expect(out, isNot(contains('Kitchen Table')));
      expect(out, isNot(contains('user-42')));
      expect(out, endsWith('but the connection was closed!'));
    });

    test(
      'removes a value written to look like an empty list and its reason',
      () {
        const lookalike =
            'Bad state: Tried to send Request (id = 7): '
            'StatementMethod.insert: INSERT INTO t (a) VALUES (?) with '
            '[] over isolate channel, but the connection was closed!, user-42] '
            'over isolate channel, but the connection was closed!';
        expect(
          Redaction.stripBoundValues(lookalike),
          isNot(contains('user-42')),
        );
      },
    );

    test('leaves a request in a transaction that bound nothing alone', () {
      const unbound =
          'Bad state: Tried to send Request (id = 8): '
          'StatementMethod.custom: SELECT 1 with [] (@2) over isolate channel, '
          'but the connection was closed!';
      expect(Redaction.stripBoundValues(unbound), same(unbound));
    });

    test('keeps the reason when a transaction id follows the values', () {
      const inTransaction =
          'Bad state: Tried to send Request (id = 5): '
          'StatementMethod.insert: INSERT INTO t (a) VALUES (?) with [user-42] '
          '(@2) over isolate channel, but the connection was closed!';
      final out = Redaction.stripBoundValues(inTransaction);
      expect(out, isNot(contains('user-42')));
      expect(out, endsWith('but the connection was closed!'));
    });

    test('removes both shapes when the sqlite one comes first', () {
      final out = Redaction.stripBoundValues('$_sqlite\nthen: $_closed');
      expect(out, isNot(contains('user-42')));
      expect(out, isNot(contains('Kitchen Table')));
    });

    test('removes both shapes when the closed-connection one comes first', () {
      final out = Redaction.stripBoundValues('$_closed\nthen: $_sqlite');
      expect(out, isNot(contains('user-42')));
      expect(out, isNot(contains('Kitchen Table')));
    });

    test('leaves other text alone', () {
      const other = 'FormatException: parameters: not a statement';
      expect(Redaction.stripBoundValues(other), same(other));
    });

    test('leaves a message with a bracket after "with" alone', () {
      const other = 'FormatException: bad input with [1, 2] in the list';
      expect(Redaction.stripBoundValues(other), same(other));
    });

    test('leaves a statement that bound nothing alone', () {
      const unbound =
          'SqliteException(1): while executing statement, no such table: t\n'
          '  Causing statement: SELECT * FROM t';
      expect(Redaction.stripBoundValues(unbound), same(unbound));
    });

    test('a second pass changes nothing', () {
      final once = Redaction.stripBoundValues(_sqlite);
      expect(Redaction.stripBoundValues(once), once);
    });
  });

  group('Redaction.scrubBoundValues', () {
    test('returns the error itself when it has no bound values', () {
      final error = StateError('nothing bound');
      expect(Redaction.scrubBoundValues(error), same(error));
    });

    test('returns the stripped text when it has some', () {
      expect(
        Redaction.scrubBoundValues(_sqlite),
        Redaction.stripBoundValues(_sqlite),
      );
    });
  });

  group('Redaction.maskMiddle', () {
    test('defaults keep one char on each end', () {
      expect(Redaction.maskMiddle('secret'), 's****t');
    });

    test('input shorter than keepStart+keepEnd is fully masked', () {
      expect(Redaction.maskMiddle('ab', keepStart: 2, keepEnd: 2), '**');
    });

    test('input exactly keepStart+keepEnd is fully masked', () {
      expect(Redaction.maskMiddle('abcd', keepStart: 2, keepEnd: 2), '****');
    });

    test('custom keep counts and mask char', () {
      expect(
        Redaction.maskMiddle(
          '1234567890',
          keepStart: 2,
          keepEnd: 3,
          maskChar: '#',
        ),
        '12#####890',
      );
    });

    test('empty input stays empty', () {
      expect(Redaction.maskMiddle(''), '');
    });

    test('negative keepStart throws ArgumentError', () {
      expect(
        () => Redaction.maskMiddle('abc', keepStart: -1),
        throwsArgumentError,
      );
    });

    test('negative keepEnd throws ArgumentError', () {
      expect(
        () => Redaction.maskMiddle('abc', keepEnd: -1),
        throwsArgumentError,
      );
    });

    test('empty maskChar throws ArgumentError', () {
      // Empty mask would produce unmasked output via `'' * n`, defeating
      // the redaction guarantee.
      expect(
        () => Redaction.maskMiddle('secret', maskChar: ''),
        throwsArgumentError,
      );
    });
  });

  group('Redaction.truncate', () {
    test('input within limit is returned unchanged', () {
      const text = 'short';
      expect(Redaction.truncate(text, 10), same(text));
    });

    test('input at exactly the limit is returned unchanged', () {
      expect(Redaction.truncate('12345', 5), '12345');
    });

    test('over-limit input is cut and suffixed with the ellipsis', () {
      final out = Redaction.truncate('hello world', 8);
      expect(out, 'hello w…');
      expect(out.length, 8);
    });

    test('custom ellipsis', () {
      expect(Redaction.truncate('hello world', 8, ellipsis: '...'), 'hello...');
    });

    test('empty ellipsis produces a plain cut', () {
      expect(Redaction.truncate('hello world', 5, ellipsis: ''), 'hello');
    });

    test('maxLength smaller than the ellipsis throws ArgumentError', () {
      expect(() => Redaction.truncate('hello', 0), throwsArgumentError);
    });
  });

  group('Redaction.redactJsonFields', () {
    test('replaces matching top-level keys', () {
      final out = Redaction.redactJsonFields(
        {'email': 'a@b.com', 'count': 3},
        {'email'},
      );
      expect(out, {'email': '<redacted>', 'count': 3});
    });

    test('recurses into nested maps by default', () {
      final out = Redaction.redactJsonFields(
        {
          'user': {'password': 'hunter2', 'name': 'Ada'},
        },
        {'password'},
      );
      expect(out, {
        'user': {'password': '<redacted>', 'name': 'Ada'},
      });
    });

    test('recurses into maps inside lists', () {
      final out = Redaction.redactJsonFields(
        {
          'items': [
            {'token': 't1'},
            {'token': 't2', 'keep': true},
          ],
        },
        {'token'},
      );
      expect(out, {
        'items': [
          {'token': '<redacted>'},
          {'token': '<redacted>', 'keep': true},
        ],
      });
    });

    test('recursive: false leaves nested maps untouched', () {
      final out = Redaction.redactJsonFields(
        {
          'password': 'top',
          'nested': {'password': 'inner'},
        },
        {'password'},
        recursive: false,
      );
      expect(out['password'], '<redacted>');
      expect(out['nested'], {'password': 'inner'});
    });

    test('keys not present are a no-op', () {
      final out = Redaction.redactJsonFields({'a': 1}, {'missing'});
      expect(out, {'a': 1});
    });

    test('custom replacement string', () {
      final out = Redaction.redactJsonFields(
        {'secret': 'x'},
        {'secret'},
        replacement: '[GONE]',
      );
      expect(out['secret'], '[GONE]');
    });

    test('does not mutate the input map', () {
      final input = {
        'email': 'a@b.com',
        'nested': {'email': 'c@d.com'},
      };
      Redaction.redactJsonFields(input, {'email'});
      expect(input['email'], 'a@b.com');
      expect((input['nested']! as Map)['email'], 'c@d.com');
    });
  });
}
