import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  group('Redaction.redactName', () {
    // Behaviour pinned to the original helpers promoted out of
    // packages/features/auth/lib/src/bloc/auth_event.dart. Any change
    // here is a behavioural change for auth event logging too.
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
        Redaction.maskMiddle('1234567890', keepStart: 2, keepEnd: 3, maskChar: '#'),
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
