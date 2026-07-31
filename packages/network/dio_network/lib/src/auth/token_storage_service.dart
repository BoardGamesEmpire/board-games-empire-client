import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:models/dto.dart';

/// Custody of the per-server session material in the platform keychain.
///
/// Keys are namespaced by local server ID to prevent cross-server
/// collisions.
///
/// ## What is persisted (#98)
///
/// One merged JSON payload per server, holding the bearer token, the
/// **server-confirmed** expiry (nullable), the moment the payload was
/// written, and a snapshot of the authenticated [AuthUser]. A single
/// payload rather than sibling keys is deliberate: store and clear are
/// then atomic by construction, so a sign-out cannot leave a user
/// snapshot behind because someone forgot to delete a second key.
///
/// **This payload contains PII.** The [AuthUser] snapshot carries the
/// user's email, display name, and avatar URL. That is why it lives in
/// `flutter_secure_storage` (Keychain / EncryptedSharedPreferences) and
/// not in the app's ordinary preferences, and why [clear] must remain the
/// single, total teardown path. The snapshot exists because #135's
/// per-(server, user) dependency scope activates on a real user id, which
/// an offline cold start has no other way to learn.
///
/// ## Confirmed vs unknown expiry
///
/// [store] takes a **nullable** `expiresAt`, and null means *unknown*, not
/// *expired*. Only a successful `GET /get-session` yields a real expiry;
/// a sign-in response does not carry one. The repository therefore writes
/// null at sign-in and a real value on reconcile. Consumers must not treat
/// unknown as dead — the token is still the credential, and the server
/// remains the authority on whether it works. What unknown *does* forbid
/// is optimistic offline entry (#98): entering the app on a session whose
/// lifetime we invented is exactly the guess this design removes. See
/// backend issue for advertising session TTL in the well-known document,
/// which would let sign-in derive a trustworthy provisional value.
///
/// ## Payload versioning
///
/// [payloadVersion] 2 introduced `persisted_at` and `user`. A version-1
/// payload (token + a client-fabricated 7-day expiry) is read back with
/// its expiry **discarded**: v1 cannot distinguish a fabricated expiry
/// from a reconciled one, and admitting a fabricated one to the offline
/// restore path would reintroduce the guess. The next successful
/// `getSession` rewrites the payload as v2.
///
/// ## Sign-out latch (#37 / PR #99)
///
/// This service is the single session-material source read by BOTH
/// `AuthRepositoryImpl` and the per-server `TokenInterceptor`. [clear]
/// sets a process-lifetime latch so that, if the underlying keychain
/// delete throws and the payload physically survives, [retrieve] (and
/// therefore [hasToken], the interceptor's `Authorization` attachment,
/// and any same-process `getSession`) all report "nothing stored"
/// immediately. This makes the "sign-out is effective for this process"
/// guarantee hold at the HTTP layer, not just in the repository's
/// in-memory auth state — an unauthenticated user can no longer keep
/// making authenticated requests because a persisted clear failed. The
/// latch is lifted only when a new payload is [store]d (a fresh
/// sign-in/up), which supersedes the prior session.
///
/// The latch is in-memory and process-scoped: it is NOT persisted. A
/// payload that survived a failed delete therefore remains on disk, and a
/// fresh [TokenStorageService] on the next cold start reads it again. The
/// residual risk is that surviving material restoring a session on the
/// next launch, where sign-out can simply be repeated — matching the
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

  /// Schema version of the persisted payload. Bump when the shape changes
  /// and extend [_decode] with the compatibility rule.
  static const int payloadVersion = 2;

  /// Process-lifetime latch set by [clear]; see the class docs. When true,
  /// [retrieve] returns null regardless of persisted state.
  bool _clearedThisProcess = false;

  String get _key => '${_prefix}_$_serverId';

  /// Persists the session material, replacing any prior payload.
  ///
  /// [expiresAt] must be a **server-confirmed** expiry or null; never a
  /// client-side estimate — it lives on the *server's* timeline.
  ///
  /// [persistedAt] is the opposite: a **raw device-clock** stamp, read from
  /// `DateTime.now()` and deliberately NOT skew-corrected. Its only job is
  /// to let a later read ask "has this device's clock moved backwards since
  /// we wrote this?", which is a question about the device's own timeline.
  /// Writing a corrected value here would compare two different clocks —
  /// see [StoredSession.isDeviceClockPlausibleAt].
  ///
  /// Neither stamp is read from a clock owned by this service: it is a
  /// keychain codec, and the repository that owns the clocks is also the one
  /// that interprets time.
  ///
  /// [user] may be omitted only where no snapshot is available; without it
  /// the session cannot be restored offline (#98).
  Future<void> store({
    required String token,
    required DateTime? expiresAt,
    required DateTime persistedAt,
    AuthUser? user,
  }) async {
    final payload = jsonEncode({
      'v': payloadVersion,
      'token': token,
      'expires_at': expiresAt?.toUtc().toIso8601String(),
      'persisted_at': persistedAt.toUtc().toIso8601String(),
      'user': user?.toJson(),
    });
    await _storage.write(key: _key, value: payload);
    // Newly stored material supersedes any prior sign-out: lift the latch.
    _clearedThisProcess = false;
  }

  Future<StoredSession?> retrieve() async {
    // Honor the sign-out latch even if the persisted delete failed and the
    // material physically survives — no consumer (repository or
    // interceptor) may resurrect it within this process.
    if (_clearedThisProcess) return null;

    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return _decode(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await clear();
      return null;
    }
  }

  /// Deletes the persisted payload and latches this service into a
  /// "signed-out" state for the process lifetime (see class docs). The
  /// latch is set FIRST, so even if the underlying delete throws,
  /// [retrieve] already reports nothing stored; the delete error still
  /// propagates so callers can surface a persistence failure.
  Future<void> clear() async {
    _clearedThisProcess = true;
    await _storage.delete(key: _key);
  }

  Future<bool> hasToken() async => (await retrieve()) != null;

  StoredSession _decode(Map<String, dynamic> map) {
    final version = map['v'];
    final isV2 = version is int && version >= 2;

    return StoredSession(
      token: map['token'] as String,
      // v1 payloads carried a client-fabricated expiry indistinguishable
      // from a reconciled one — discard it rather than let a guess gate
      // offline restore.
      expiresAt: isV2 ? _parseUtc(map['expires_at']) : null,
      // v1 has no persisted_at. Epoch is the honest floor: it makes the
      // "clock moved backwards" guard vacuously pass, which is harmless
      // because a v1 payload has no user snapshot and so can never
      // qualify for offline restore anyway.
      persistedAt:
          _parseUtc(map['persisted_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      user: _parseUser(map['user']),
    );
  }

  static DateTime? _parseUtc(Object? value) =>
      value is String ? DateTime.parse(value).toUtc() : null;

  /// Decodes the user snapshot, tolerating a malformed one.
  ///
  /// Isolated from the payload-level catch on purpose: a corrupt snapshot
  /// must degrade to "no offline restore", not to a forced sign-out. The
  /// token beside it may be perfectly good, and throwing away a working
  /// credential because an avatar URL failed to parse would be a worse
  /// outcome than the feature simply being unavailable until the next
  /// successful `getSession` rewrites it.
  static AuthUser? _parseUser(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    try {
      return AuthUser.fromJson(value);
    } catch (_) {
      return null;
    }
  }
}

/// The persisted per-server session material (#98).
///
/// Named for what it is: not just a token, but everything this device
/// remembers about the session — including a user snapshot that is PII.
/// Time-dependent questions take an explicit `now` rather than reading a
/// clock, so this stays a pure value object and the caller's per-server
/// [ClockService] remains the single time authority.
@immutable
class StoredSession {
  const StoredSession({
    required this.token,
    required this.persistedAt,
    this.expiresAt,
    this.user,
  });

  /// The bearer credential.
  final String token;

  /// When this payload was written, by the **raw device clock**. Used only
  /// to detect a device clock that has since moved backwards; never compared
  /// against server-derived time.
  final DateTime persistedAt;

  /// Server-confirmed expiry, or null when the server has never told us
  /// one. Null means **unknown**, not expired.
  final DateTime? expiresAt;

  /// Snapshot of the authenticated user, or null for a pre-#98 payload or
  /// one whose snapshot failed to decode.
  final AuthUser? user;

  /// Whether the server has confirmed an expiry for this session.
  bool get hasConfirmedExpiry => expiresAt != null;

  /// Whether the session is **known** to be dead at [correctedNowUtc].
  ///
  /// An unknown expiry is deliberately not expired: the token is still the
  /// credential and the server decides. Callers gating network requests
  /// want this; callers gating offline entry want [canRestoreOffline].
  bool isExpiredAt(DateTime correctedNowUtc) {
    final expiry = expiresAt;
    return expiry != null && correctedNowUtc.isAfter(expiry);
  }

  /// Whether the device's own clock is plausible — i.e. it has not moved
  /// backwards past the moment this payload was written.
  ///
  /// [deviceNowUtc] MUST be a raw device reading, matching how [persistedAt]
  /// was written. Passing a skew-corrected value here compares two clocks
  /// and produces a false negative on exactly the devices that need this
  /// feature most: `persistedAt` is stamped during an online session, so on
  /// a device whose clock lags the server by Δ a corrected reading sits ~Δ
  /// ahead of the raw one. Compare corrected-against-raw and the guard
  /// reports "clock moved backwards" for the first Δ after every successful
  /// `getSession` — silently refusing offline restore for an hour on a
  /// device an hour behind. There is no corrected estimate at an offline
  /// cold start anyway (no `Date` samples yet, and persistence is #117), so
  /// raw-against-raw is both the correct comparison and the only available
  /// one.
  bool isDeviceClockPlausibleAt(DateTime deviceNowUtc) =>
      !deviceNowUtc.isBefore(persistedAt);

  /// Whether this material is sufficient to enter the app optimistically
  /// while the server is unreachable (#98). See
  /// `AuthRepository.getCachedSession` for the rationale behind each
  /// clause.
  ///
  /// Two clocks, two questions, deliberately not interchangeable:
  /// [correctedNowUtc] answers "has the session expired?", which is on the
  /// server's timeline and therefore wants the skew-corrected reading;
  /// [deviceNowUtc] answers "is this device's clock self-consistent?",
  /// which is on the device's timeline and wants the raw one.
  bool canRestoreOffline({
    required DateTime correctedNowUtc,
    required DateTime deviceNowUtc,
  }) =>
      user != null &&
      hasConfirmedExpiry &&
      isDeviceClockPlausibleAt(deviceNowUtc) &&
      !isExpiredAt(correctedNowUtc);
}
