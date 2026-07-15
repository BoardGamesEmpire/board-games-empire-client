import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores and retrieves per-server session tokens in the platform keychain.
///
/// Keys are namespaced by local server ID to prevent cross-server collisions.
/// Only the token string and expiry are persisted — the full [AuthResponse]
/// is reconstructed after a [getSession] network call.
///
/// ## Sign-out latch (#37 / PR #99)
///
/// This service is the single token-material source read by BOTH
/// `AuthRepositoryImpl` and the per-server `TokenInterceptor`. [clear] sets
/// a process-lifetime latch so that, if the underlying keychain delete
/// throws and the token physically survives, [retrieve] (and therefore
/// [hasToken], the interceptor's `Authorization` attachment, and any
/// same-process `getSession`) all report "no token" immediately. This makes
/// the "sign-out is effective for this process" guarantee hold at the HTTP
/// layer, not just in the repository's in-memory auth state — an
/// unauthenticated user can no longer keep making authenticated requests
/// because a persisted clear failed. The latch is lifted only when a new
/// token is [store]d (a fresh sign-in/up), which supersedes the prior
/// session.
///
/// The latch is in-memory and process-scoped: it is NOT persisted. A token
/// that survived a failed delete therefore remains on disk, and a fresh
/// [TokenStorageService] on the next cold start reads it again. The residual
/// risk is that surviving token restoring a session on the next launch,
/// where sign-out can simply be repeated — matching the
/// `AuthRepository.signOut` contract.
class TokenStorageService {
  TokenStorageService({
    required String serverId,
    @visibleForTesting FlutterSecureStorage? storage,
  }) : _serverId = serverId,
       _storage = storage ?? const FlutterSecureStorage();

  final String _serverId;
  final FlutterSecureStorage _storage;

  static const String _prefix = 'bge_session';

  /// Process-lifetime latch set by [clear]; see the class docs. When true,
  /// [retrieve] returns null regardless of persisted state.
  bool _clearedThisProcess = false;

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
    // A newly stored token supersedes any prior sign-out: lift the latch.
    _clearedThisProcess = false;
  }

  Future<StoredToken?> retrieve() async {
    // Honor the sign-out latch even if the persisted delete failed and the
    // token physically survives — no consumer (repository or interceptor)
    // may resurrect it within this process.
    if (_clearedThisProcess) return null;

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

  /// Deletes the persisted token and latches this service into a
  /// "signed-out" state for the process lifetime (see class docs). The
  /// latch is set FIRST, so even if the underlying delete throws, [retrieve]
  /// already reports no token; the delete error still propagates so callers
  /// can surface a persistence failure.
  Future<void> clear() async {
    _clearedThisProcess = true;
    await _storage.delete(key: _key);
  }

  Future<bool> hasToken() async => (await retrieve()) != null;
}

class StoredToken {
  const StoredToken({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
}
