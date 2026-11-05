import 'package:dio_network/src/auth/provider_sign_in/server_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ignores a trailing slash, host case and an explicit default port', () {
    expect(
      isSameServerAddress(
        'https://BGE.example.com:443/',
        'https://bge.example.com',
      ),
      isTrue,
    );
    expect(isSameServerAddress('http://a.com:80', 'HTTP://a.com/'), isTrue);
    expect(
      isSameServerAddress('https://a.com/bge/', 'https://a.com/bge'),
      isTrue,
    );
  });

  test('ignores query, fragment and userinfo', () {
    expect(
      isSameServerAddress('https://a.com/?x=1#f', 'https://a.com'),
      isTrue,
    );
    expect(isSameServerAddress('https://u:p@a.com', 'https://a.com'), isTrue);
  });

  test('tells hosts, schemes, ports and paths apart', () {
    expect(
      isSameServerAddress('https://bge.example.com', 'https://192.168.1.5'),
      isFalse,
    );
    expect(
      isSameServerAddress('http://bge.example.com', 'https://bge.example.com'),
      isFalse,
    );
    expect(
      isSameServerAddress(
        'https://bge.example.com:8443',
        'https://bge.example.com',
      ),
      isFalse,
    );
    expect(
      isSameServerAddress('https://example.com/bge', 'https://example.com'),
      isFalse,
    );
    expect(
      isSameServerAddress('https://example.com/BGE', 'https://example.com/bge'),
      isFalse,
    );
  });

  test(
    'an address that does not parse or lacks scheme or host is never the same',
    () {
      expect(isSameServerAddress('', ''), isFalse);
      expect(
        isSameServerAddress('bge.example.com', 'bge.example.com'),
        isFalse,
      );
      expect(isSameServerAddress('https://', 'https://'), isFalse);
      expect(isSameServerAddress('http://[bad', 'http://[bad'), isFalse);
      expect(isSameServerAddress('/path', '/path'), isFalse);
    },
  );

  group('resolveServerEndpoint', () {
    test('keeps the path prefix of a server reached under one', () {
      expect(
        resolveServerEndpoint(
          'https://example.com/bge',
          '/api/auth/app-sign-in/token',
        ),
        Uri.parse('https://example.com/bge/api/auth/app-sign-in/token'),
      );
    });

    test('drops one trailing slash from the server address', () {
      expect(
        resolveServerEndpoint(
          'https://example.com/bge/',
          '/api/auth/app-sign-in/token',
        ),
        Uri.parse('https://example.com/bge/api/auth/app-sign-in/token'),
      );
      expect(
        resolveServerEndpoint(
          'https://api.example.com/',
          '/api/auth/app-sign-in/start',
        ),
        Uri.parse('https://api.example.com/api/auth/app-sign-in/start'),
      );
    });

    test('appends the path to a server address with none', () {
      expect(
        resolveServerEndpoint(
          'https://api.example.com',
          '/api/auth/app-sign-in/start',
        ),
        Uri.parse('https://api.example.com/api/auth/app-sign-in/start'),
      );
    });

    test('keeps an http or https endpoint on the server\'s own origin', () {
      expect(
        resolveServerEndpoint(
          'https://example.com/bge',
          'https://example.com/app-sign-in/start',
        ),
        Uri.parse('https://example.com/app-sign-in/start'),
      );
      expect(
        resolveServerEndpoint(
          'http://10.0.0.2:3000',
          'http://10.0.0.2:3000/app-sign-in/token',
        ),
        Uri.parse('http://10.0.0.2:3000/app-sign-in/token'),
      );
      expect(
        resolveServerEndpoint(
          'https://Example.com',
          'https://example.com:443/app-sign-in/token',
        ),
        Uri.parse('https://example.com/app-sign-in/token'),
        reason: 'host case and the default port are the same origin',
      );
    });

    test('is null for an absolute endpoint on another origin', () {
      for (final (endpoint, reason) in [
        ('https://auth.example.com/app-sign-in/token', 'another host'),
        ('http://example.com/app-sign-in/token', 'cleartext under https'),
        ('https://example.com:8443/app-sign-in/token', 'another port'),
      ]) {
        expect(
          resolveServerEndpoint('https://example.com/bge', endpoint),
          isNull,
          reason: reason,
        );
      }
    });

    test('is null when no address can be made, rather than throwing', () {
      expect(
        resolveServerEndpoint('https://example.com', 'https://[bad/start'),
        isNull,
        reason: 'a malformed absolute endpoint',
      );
      expect(
        resolveServerEndpoint('https://[bad', '/api/auth/app-sign-in/start'),
        isNull,
        reason: 'a malformed server address',
      );
      expect(
        resolveServerEndpoint('https://example.com', 'https:/app-sign-in'),
        isNull,
        reason: 'an absolute endpoint with no host',
      );
    });
  });
}
