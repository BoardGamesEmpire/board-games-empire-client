import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 32 random bytes from [random] (default [Random.secure]) as base64url
/// without padding: 43 characters. Used for both the PKCE verifier and the
/// `state` (#583).
String randomUrlSafeToken([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => source.nextInt(256));

  return _unpadded(base64Url.encode(bytes));
}

/// The S256 challenge for [verifier]: base64url, without padding, of the
/// SHA-256 of its ASCII bytes (RFC 7636 section 4.2).
String codeChallengeS256(String verifier) =>
    _unpadded(base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes));

String _unpadded(String encoded) => encoded.replaceAll('=', '');
