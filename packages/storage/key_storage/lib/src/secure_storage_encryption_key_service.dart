import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
/// ## Where the keys are kept (#428)
///
/// On Android, [SecureStorageEncryptionKeyService.platform] keeps the keys
/// in a store of their own ([androidKeyStoreOptions]): its own preferences
/// file, Keystore alias and settings. The plugin shares one native store
/// between every `FlutterSecureStorage` that names no namespace, and applies
/// the settings of whichever call reached it first. Session tokens live in
/// that shared store, and a token call that fails with the default settings
/// clears the whole store, keys included
/// (`FlutterSecureStoragePlugin.java:237-240` in flutter_secure_storage
/// 11.0.0).
///
/// Both stores turn `resetOnError` off. With it on, a read error deletes the
/// entry and the read returns null, which looks exactly like "no key".
///
/// Keys written before the move live in the shared store. Only a find
/// ([findServerKey], [findMetaKey]) looks there, which is what a database
/// file that already exists asks for: a key found only in the shared store
/// is copied into the key store and then deleted from the shared one, once.
/// A get-or-create reads the key store alone, because its file does not
/// exist yet, so no moved key could open it. A fresh install therefore
/// never touches the shared store, and an upgraded one only on the boot
/// that moves its keys. On that boot the first call to the shared store
/// is the move (the meta database opens before anything reads a token), so
/// its settings hold for the session's token calls too: a failed token
/// read clears the shared store instead of resetting one entry. That costs
/// a sign-in, and any key not moved yet, which is a disconnected server's,
/// as only connected servers open their databases at start-up. Apple and
/// desktop platforms ignore Android options, so there the two stores are
/// one and nothing moves.
///
/// ## Failures
///
/// A failure of the store itself leaves as [EncryptionKeyUnavailableError],
/// never as a missing key, so no caller replaces a key it could not read.
///
/// ## Crash safety
///
/// A newly generated key is written to secure storage *before* it is
/// returned, so no caller can encrypt a database with a key that was never
/// persisted. A moved key is written to the key store before it is deleted
/// from the shared one.
///
/// ## Concurrency (#185)
///
/// Operations on one entry run one at a time: a get, a find or a delete
/// waits for any operation on the same entry that started before it. A
/// creation and a delete therefore never interleave, and two callers racing
/// to create a key receive the same one.
///
/// The guarantee holds per instance, within one isolate. Production builds
/// one instance per process (`NativePlatformBootstrap` asserts that its
/// storage installers share it). The keychain entry belongs to the app
/// across processes, though, so safety across processes rests on the
/// desktop app running once: enforced on Linux, best effort on Windows, and
/// the LaunchServices default on macOS, which `open -n` bypasses.
class SecureStorageEncryptionKeyService implements EncryptionKeyService {
  /// Creates the service.
  ///
  /// [_storage] holds the keys. [_legacyStorage], when given, is the store
  /// keys used to live in; a key found only there moves to [_storage] (see
  /// the class docs). Production uses [SecureStorageEncryptionKeyService.platform].
  ///
  /// [random] must be cryptographically secure and defaults to
  /// [Random.secure] — it is injectable only so tests can make generation
  /// deterministic.
  SecureStorageEncryptionKeyService({
    required this._storage,
    this._legacyStorage,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// The production service, over the stores the class docs describe.
  factory SecureStorageEncryptionKeyService.platform() =>
      SecureStorageEncryptionKeyService(
        storage: const FlutterSecureStorage(aOptions: androidKeyStoreOptions),
        legacyStorage: const FlutterSecureStorage(
          aOptions: androidSharedStoreOptions,
        ),
      );

  /// Android settings of the store the keys live in.
  @visibleForTesting
  static const androidKeyStoreOptions = AndroidOptions(
    resetOnError: false,
    storageNamespace: 'bge_encryption_keys',
  );

  /// Android settings for reaching the shared store that keys move out of.
  @visibleForTesting
  static const androidSharedStoreOptions = AndroidOptions(resetOnError: false);

  static const _prefix = 'encryption_key:';
  static const _metaIdentifier = 'meta';

  /// Number of random bytes per key: 256 bits.
  static const _keyLengthBytes = 32;

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage? _legacyStorage;
  final Random _random;

  /// The last operation queued on each entry; see [_serialized].
  final Map<String, Future<void>> _tails = {};

  @override
  Future<String> getOrCreateServerKey(String serverId) =>
      _getOrCreate(_serverEntry(serverId));

  @override
  Future<String> getOrCreateMetaKey() =>
      _getOrCreate('$_prefix$_metaIdentifier');

  @override
  Future<String?> findServerKey(String serverId) {
    final entry = _serverEntry(serverId);
    return _serialized(entry, () => _find(entry));
  }

  @override
  Future<String?> findMetaKey() {
    const entry = '$_prefix$_metaIdentifier';
    return _serialized(entry, () => _find(entry));
  }

  @override
  Future<void> deleteServerKey(String serverId) =>
      _delete(_serverEntry(serverId));

  @override
  Future<void> deleteMetaKey() => _delete('$_prefix$_metaIdentifier');

  /// The entry for [serverId]. Throws [ArgumentError] synchronously for an
  /// empty or reserved id.
  String _serverEntry(String serverId) {
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
    return '$_prefix$serverId';
  }

  /// Reads the key store only: see the class docs on where a move happens.
  Future<String> _getOrCreate(String entry) => _serialized(entry, () async {
    final existing = await _storage.read(key: entry);
    if (existing != null) return existing;

    final generated = _generateKey();
    // Persist before returning — see class docs on crash safety.
    await _storage.write(key: entry, value: generated);
    return generated;
  });

  /// Reads [entry], first moving it out of the shared store if that is the
  /// only place it is held. Runs inside [_serialized].
  Future<String?> _find(String entry) async {
    final stored = await _storage.read(key: entry);
    if (stored != null) return stored;

    final legacy = _legacyStorage;
    if (legacy == null) return null;
    final shared = await legacy.read(key: entry);
    if (shared == null) return null;

    await _storage.write(key: entry, value: shared);
    await legacy.delete(key: entry);
    return shared;
  }

  Future<void> _delete(String entry) => _serialized(entry, () async {
    await _storage.delete(key: entry);
    await _legacyStorage?.delete(key: entry);
  });

  /// Runs [operation] once every operation queued earlier on [entry] has
  /// finished, whether it succeeded or failed. A failure reaches only its
  /// own caller; the next operation runs as usual.
  ///
  /// The store's own failures leave as [EncryptionKeyUnavailableError].
  Future<T> _serialized<T>(String entry, Future<T> Function() operation) {
    final previous = _tails[entry] ?? Future<void>.value();
    final result = previous.then((_) => _reportingStoreFailures(operation));
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _tails[entry] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[entry], tail)) _tails.remove(entry);
      }),
    );
    return result;
  }

  static Future<T> _reportingStoreFailures<T>(
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on PlatformException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        EncryptionKeyUnavailableError(cause: error),
        stackTrace,
      );
    }
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
