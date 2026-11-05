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
}
