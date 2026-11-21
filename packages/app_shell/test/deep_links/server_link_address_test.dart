import 'package:app_shell/src/deep_links/deep_link_normalizer.dart';
import 'package:app_shell/src/deep_links/server_link_address.dart';
import 'package:flutter_test/flutter_test.dart';

/// `serverLinkAddress` and `serverDeepLinkFromLocation` — the optional
/// `?address=<server base URL>` a `bge://server/...` link can carry (#971).
void main() {
  group('serverLinkAddress', () {
    group('returns the normalized address', () {
      const cases = {
        '/server/abc/event/1?address=https%3A%2F%2Fexample.org%2Fbge%2F':
            'https://example.org/bge',
        '/server/abc/event/1?address=example.org': 'https://example.org',
        '/server/abc/event/1?address=http%3A%2F%2F192.168.1.10%3A3000':
            'http://192.168.1.10:3000',
      };
      for (final entry in cases.entries) {
        test('${entry.key} gives ${entry.value}', () {
          expect(serverLinkAddress(entry.key), entry.value);
        });
      }
    });

    group('returns null', () {
      const cases = {
        'no address': '/server/abc/event/1',
        'no address among other parameters': '/server/abc/event/1?c=1',
        'an empty value': '/server/abc/event/1?address=',
        'a value that carries userinfo': '/server/abc/event/1?address=https%3A%2F%2Falice%3Apw%40example.org',
        'a bare user@host': '/server/abc/event/1?address=alice%40example.org',
        'an @ in the path':
            '/server/abc/event/1?address=https%3A%2F%2Fexample.org%2Fa%40b',
        'a javascript: value':
            '/server/abc/event/1?address=javascript%3Aalert(1)',
        'an ftp address': '/server/abc/event/1?address=ftp%3A%2F%2Fexample.org',
        'plain http to a public host':
            '/server/abc/event/1?address=http%3A%2F%2Fexample.org',
        'a repeated address': '/server/abc/event/1?address=a&address=b',
        'a repeated address with the same value':
            '/server/abc/event/1?address=example.org&address=example.org',
        'a query that cannot be decoded': '/server/abc/event/1?address=%FF',
      };
      for (final entry in cases.entries) {
        test(entry.key, () {
          expect(serverLinkAddress(entry.value), isNull);
        });
      }

      test('a location that cannot be parsed at all', () {
        expect(serverLinkAddress('http://[::1'), isNull);
      });
    });
  });

  group('serverDeepLinkFromLocation', () {
    test('re-normalizes a server location to the link it came from', () {
      const location = '/server/abc/event/1?address=x';

      final expected = (normalizeDeepLink(
        Uri.parse('bge://server/abc/event/1?address=x'),
      ) as DeepLinkNormalized).link;

      expect(serverDeepLinkFromLocation(location), expected);
      expect(serverDeepLinkFromLocation(location), isA<ServerDeepLink>());
    });

    const rejected = {
      'an app location': '/settings',
      'a server with no resource path': '/server/abc',
      'text that is not a path': 'not a path',
      'a server id that cannot be decoded': '/server/%FF/event/1',
    };
    for (final entry in rejected.entries) {
      test('is null for ${entry.key}', () {
        expect(serverDeepLinkFromLocation(entry.value), isNull);
      });
    }

    test('is null for a location that cannot be parsed', () {
      expect(serverDeepLinkFromLocation('/[::1'), isNull);
    });
  });
}
