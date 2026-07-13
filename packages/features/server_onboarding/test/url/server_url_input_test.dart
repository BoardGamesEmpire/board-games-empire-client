import 'package:flutter_test/flutter_test.dart';
import 'package:server_onboarding/server_onboarding.dart';

void main() {
  group('normalizeServerUrl', () {
    group('malformed input', () {
      for (final input in ['', '   ', 'ht tp://x', 'https://']) {
        test('rejects ${input.isEmpty ? '<empty>' : '"$input"'}', () {
          expect(
            normalizeServerUrl(input),
            const ServerUrlInvalid(ServerUrlError.malformed),
          );
        });
      }

      // Uri.parse is lenient and will happily percent-encode a space
      // into the authority ("https://ht tp://x" → host "ht%20tp")
      // instead of throwing; the host-shape guard must reject these.
      for (final input in [
        'ht tp://x',
        'bge example.com',
        'https://exa mple.com',
        'https://%00',
      ]) {
        test('rejects host-malformed "$input"', () {
          expect(
            normalizeServerUrl(input),
            const ServerUrlInvalid(ServerUrlError.malformed),
          );
        });
      }
    });

    group('scheme handling', () {
      test('prepends https when no scheme is given', () {
        expect(
          normalizeServerUrl('bge.example.com'),
          const ServerUrlValid('https://bge.example.com'),
        );
      });

      test('accepts explicit https', () {
        expect(
          normalizeServerUrl('https://bge.example.com'),
          const ServerUrlValid('https://bge.example.com'),
        );
      });

      test('rejects non-http(s) schemes', () {
        expect(
          normalizeServerUrl('ftp://bge.example.com'),
          const ServerUrlInvalid(ServerUrlError.unsupportedScheme),
        );
      });

      test('rejects plain http toward a public host', () {
        expect(
          normalizeServerUrl('http://bge.example.com'),
          const ServerUrlInvalid(ServerUrlError.insecureHttp),
        );
      });
    });

    group('http exemptions for self-hosting (loopback + RFC 1918)', () {
      for (final host in [
        'localhost',
        '127.0.0.1',
        '127.8.8.8',
        '[::1]',
        '10.0.0.5',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.10',
      ]) {
        test('allows http://$host', () {
          expect(
            normalizeServerUrl('http://$host:3000'),
            ServerUrlValid('http://$host:3000'),
          );
        });
      }

      for (final host in ['172.15.0.1', '172.32.0.1', '11.0.0.1', '8.8.8.8']) {
        test('rejects http://$host (public)', () {
          expect(
            normalizeServerUrl('http://$host'),
            const ServerUrlInvalid(ServerUrlError.insecureHttp),
          );
        });
      }
    });

    group('normalization', () {
      test('trims surrounding whitespace', () {
        expect(
          normalizeServerUrl('  https://bge.example.com  '),
          const ServerUrlValid('https://bge.example.com'),
        );
      });

      test('drops a trailing slash', () {
        expect(
          normalizeServerUrl('https://bge.example.com/'),
          const ServerUrlValid('https://bge.example.com'),
        );
      });

      test('preserves a path prefix (reverse-proxy deployment)', () {
        expect(
          normalizeServerUrl('https://shared.example.com/bge/'),
          const ServerUrlValid('https://shared.example.com/bge'),
        );
      });

      test('preserves an explicit port', () {
        expect(
          normalizeServerUrl('https://bge.example.com:8443'),
          const ServerUrlValid('https://bge.example.com:8443'),
        );
      });

      test('strips query and fragment', () {
        expect(
          normalizeServerUrl('https://bge.example.com/bge?utm=x#top'),
          const ServerUrlValid('https://bge.example.com/bge'),
        );
      });
    });
  });
}
