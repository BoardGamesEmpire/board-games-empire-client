import 'dart:math';

import 'package:dio_network/src/auth/provider_sign_in/pkce.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('codeChallengeS256 matches RFC 7636 appendix B', () {
    expect(
      codeChallengeS256('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('randomUrlSafeToken is 43 base64url characters with no padding', () {
    expect(randomUrlSafeToken(), matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
  });

  test('two tokens differ', () {
    expect(randomUrlSafeToken(), isNot(randomUrlSafeToken()));
  });

  test('a supplied Random drives the token', () {
    expect(randomUrlSafeToken(Random(1)), randomUrlSafeToken(Random(1)));
    expect(randomUrlSafeToken(Random(1)), isNot(randomUrlSafeToken(Random(2))));
  });
}
