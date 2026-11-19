import 'dart:math';

/// A random version 4 UUID, written as lower-case hex in 8-4-4-4-12 groups.
///
/// An import's correlation id (#43): the server accepts nothing but a UUID.
/// Sixteen bytes from [random], [Random.secure] unless a test passes its own,
/// with the version and variant bits set as RFC 9562 has them.
String uuidV4([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = [for (var i = 0; i < 16; i++) source.nextInt(256)];
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10

  final hex = [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')]
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
