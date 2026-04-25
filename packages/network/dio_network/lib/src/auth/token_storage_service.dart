import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores and retrieves per-server session tokens in the platform keychain.
///
/// Keys are namespaced by local server ID to prevent cross-server collisions.
/// Only the token string and expiry are persisted — the full [AuthResponse]
/// is reconstructed after a [getSession] network call.
class TokenStorageService {
  TokenStorageService({
    required String serverId,
    @visibleForTesting FlutterSecureStorage? storage,
  }) : _serverId = serverId,
       _storage = storage ?? const FlutterSecureStorage();

  final String _serverId;
  final FlutterSecureStorage _storage;

  static const String _prefix = 'bge_session';

  String get _key => '${_prefix}_$_serverId';

  Future<void> store({
    required String token,
    required DateTime expiresAt,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'expires_at': expiresAt.toUtc().toIso8601String(),
    });
    await _storage.write(key: _key, value: payload);
  }

  Future<StoredToken?> retrieve() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return StoredToken(
        token: map['token'] as String,
        expiresAt: DateTime.parse(map['expires_at'] as String),
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: _key);

  Future<bool> hasToken() async => (await retrieve()) != null;
}

class StoredToken {
  const StoredToken({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
}
