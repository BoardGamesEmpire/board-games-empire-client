import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:interfaces/services.dart';

/// [EncryptionKeyService] backed by [FlutterSecureStorage].
///
/// Platform backing: Android Keystore, macOS/iOS Keychain. The OS keychain
/// is the security boundary — keys are 256-bit random values with no user
/// passphrase, so possession of the unlocked keychain entry *is* possession
/// of the key.
///
/// ## Storage layout
///
/// | entry                       | key                          |
/// |-----------------------------|------------------------------|
/// | per-server database key     | `encryption_key:{serverId}`  |
/// | meta database key (global)  | `encryption_key:meta`        |
///
/// `meta` is reserved: a server whose id is literally `meta` would collide,
/// which [getOrCreateServerKey] refuses with an [ArgumentError]. Server ids
/// are cuid2 values in practice, so this cannot occur outside programmer
/// error.
///
/// ## Crash safety
///
/// A newly generated key is written to secure storage *before* it is
/// returned, so no caller can encrypt a database with a key that was never
/// persisted.
class SecureStorageEncryptionKeyService implements EncryptionKeyService {
  /// Creates the service.
  ///
  /// [storage] is injectable for testing; production wiring passes a default
  /// [FlutterSecureStorage]. [random] must be cryptographically secure and
  /// defaults to [Random.secure] — it is injectable only so tests can make
  /// generation deterministic.
  SecureStorageEncryptionKeyService({
    required FlutterSecureStorage storage,
    Random? random,
  }) : _storage = storage,
       _random = random ?? Random.secure();

  static const _prefix = 'encryption_key:';
  static const _metaIdentifier = 'meta';

  /// Number of random bytes per key: 256 bits.
  static const _keyLengthBytes = 32;

  final FlutterSecureStorage _storage;
  final Random _random;

  @override
  Future<String> getOrCreateServerKey(String serverId) {
    if (serverId.isEmpty) {
      throw ArgumentError.value(serverId, 'serverId', 'must not be empty');
    }
    if (serverId == _metaIdentifier) {
      throw ArgumentError.value(
        serverId,
        'serverId',
        'is reserved for the meta database key',
      );
    }
    return _getOrCreate('$_prefix$serverId');
  }

  @override
  Future<String> getOrCreateMetaKey() =>
      _getOrCreate('$_prefix$_metaIdentifier');

  @override
  Future<void> deleteServerKey(String serverId) {
    if (serverId.isEmpty) {
      throw ArgumentError.value(serverId, 'serverId', 'must not be empty');
    }
    if (serverId == _metaIdentifier) {
      throw ArgumentError.value(
        serverId,
        'serverId',
        'is reserved for the meta database key',
      );
    }

    return _storage.delete(key: '$_prefix$serverId');
  }

  @override
  Future<void> deleteMetaKey() =>
      _storage.delete(key: '$_prefix$_metaIdentifier');

  Future<String> _getOrCreate(String storageKey) async {
    final existing = await _storage.read(key: storageKey);
    if (existing != null) return existing;

    final generated = _generateKey();
    // Persist before returning — see class docs on crash safety.
    await _storage.write(key: storageKey, value: generated);
    return generated;
  }

  /// Generates a 64-character lowercase hex key (256 random bits).
  ///
  /// The hex-only alphabet is a deliberate part of the contract: consumers
  /// interpolate the key into a `PRAGMA key = '...'` statement, and
  /// restricting the character set to `[0-9a-f]` makes that interpolation
  /// injection-proof by construction.
  String _generateKey() {
    final buffer = StringBuffer();
    for (var i = 0; i < _keyLengthBytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
