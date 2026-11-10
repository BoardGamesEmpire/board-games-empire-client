import 'package:flutter_test/flutter_test.dart';
import 'package:web_network/web_network.dart';

const _kId = 'r3TurN-id_1';
const _kReturn = '$providerSignInReturnKey=$_kId';

void main() {
  group('readProviderSignInReturn', () {
    test('no marker: a ?error= in the address is ignored and left alone', () {
      final r = readProviderSignInReturn(
        marker: null,
        address: Uri.parse('https://bge.example.com/?error=access_denied'),
      );
      expect(r.startupReturn, isNull);
      expect(r.cleanedAddress, isNull);
    });

    test('marker and ?error=REGISTRATION_DISABLED: returns the code and an '
        'address without error or error_description', () {
      final r = readProviderSignInReturn(
        marker: _kId,
        address: Uri.parse(
          'https://bge.example.com/?$_kReturn&error=REGISTRATION_DISABLED'
          '&error_description=Nope&keep=1',
        ),
      );
      expect(r.startupReturn!.errorCode, 'REGISTRATION_DISABLED');
      expect(r.cleanedAddress.toString(), 'https://bge.example.com/?keep=1');
    });

    test('marker and no error: a success return, the id taken out', () {
      final r = readProviderSignInReturn(
        marker: _kId,
        address: Uri.parse('https://bge.example.com/?keep=1&$_kReturn'),
      );
      expect(r.startupReturn, isNotNull);
      expect(r.startupReturn!.errorCode, isNull);
      expect(r.cleanedAddress.toString(), 'https://bge.example.com/?keep=1');
    });

    test(
      'marker and only ?error=: the cleaned address has no query at all',
      () {
        final r = readProviderSignInReturn(
          marker: _kId,
          address: Uri.parse('https://bge.example.com/?error=denied&$_kReturn'),
        );
        expect(r.startupReturn!.errorCode, 'denied');
        expect(r.cleanedAddress.toString(), 'https://bge.example.com/');
      },
    );

    test('marker and an empty ?error=: a failed return with an empty code', () {
      final r = readProviderSignInReturn(
        marker: _kId,
        address: Uri.parse('https://bge.example.com/?$_kReturn&error='),
      );
      expect(r.startupReturn!.errorCode, '');
      expect(r.cleanedAddress.toString(), 'https://bge.example.com/');
    });

    test('a repeated error key: the first value wins, all are cleaned', () {
      final r = readProviderSignInReturn(
        marker: _kId,
        address: Uri.parse(
          'https://bge.example.com/?error=first&keep=1&$_kReturn&error=second&keep=2',
        ),
      );
      expect(r.startupReturn!.errorCode, 'first');
      expect(
        r.cleanedAddress.toString(),
        'https://bge.example.com/?keep=1&keep=2',
      );
    });

    test('the path and fragment survive cleaning', () {
      final r = readProviderSignInReturn(
        marker: _kId,
        address: Uri.parse(
          'https://bge.example.com/app?error=x&$_kReturn&a=1#frag',
        ),
      );
      expect(
        r.cleanedAddress.toString(),
        'https://bge.example.com/app?a=1#frag',
      );
    });
    test('marker but no id in the address: not a return, address left alone '
        '(a typed address or a bookmark after giving up on the provider)', () {
      for (final address in [
        'https://bge.example.com/',
        'https://bge.example.com/?error=access_denied',
      ]) {
        final r = readProviderSignInReturn(
          marker: _kId,
          address: Uri.parse(address),
        );
        expect(r.startupReturn, isNull, reason: address);
        expect(r.cleanedAddress, isNull, reason: address);
      }
    });

    test("an id that is not the marker's: not a return; the id is taken "
        'out and a ?error= stays', () {
      final r = readProviderSignInReturn(
        marker: _kId,
        address: Uri.parse(
          'https://bge.example.com/?$providerSignInReturnKey=other&error=x',
        ),
      );
      expect(r.startupReturn, isNull);
      expect(r.cleanedAddress.toString(), 'https://bge.example.com/?error=x');
    });

    test('an id with no marker, or an empty marker: not a return, the id '
        'taken out', () {
      for (final marker in [null, '']) {
        final r = readProviderSignInReturn(
          marker: marker,
          address: Uri.parse(
            'https://bge.example.com/?$providerSignInReturnKey=',
          ),
        );
        expect(r.startupReturn, isNull, reason: '$marker');
        expect(
          r.cleanedAddress.toString(),
          'https://bge.example.com/',
          reason: '$marker',
        );
      }
    });

    test('a query that does not decode: not a return, and no throw, so the '
        'app still starts on that address', () {
      for (final marker in [null, _kId]) {
        // `%FF` is not UTF-8, so `Uri.queryParametersAll` throws on it.
        final r = readProviderSignInReturn(
          marker: marker,
          address: Uri.parse('https://bge.example.com/?$_kReturn&q=%FF'),
        );
        expect(r.startupReturn, isNull, reason: '$marker');
        expect(r.cleanedAddress, isNull, reason: '$marker');
      }
    });
  });

  group('providerSignInCallback', () {
    test('is the app root carrying the return id', () {
      expect(providerSignInCallback(_kId), '/?$providerSignInReturnKey=$_kId');
    });
  });

  group('newProviderSignInReturnId', () {
    test('is 22 base64url characters, fresh each time', () {
      final ids = {for (var i = 0; i < 50; i++) newProviderSignInReturnId()};
      expect(ids, hasLength(50));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      }
    });

    test("survives the server's check of a relative callback address", () {
      // The server's pattern for a relative callback, from better-auth's
      // trusted-origins check.
      final relativeCallback = RegExp(
        r'^\/(?!\/|\\|%2f|%5c)[\w\-.\+/@]*(?:\?[\w\-.\+/=&%@]*)?$',
      );
      for (var i = 0; i < 50; i++) {
        expect(
          providerSignInCallback(newProviderSignInReturnId()),
          matches(relativeCallback),
        );
      }
    });
  });
}
