import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:models/dto.dart';

import 'package:dio_network/src/auth/token_storage_service.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

Map<String, dynamic> _wireUser() => {
  'id': 'user-1',
  'name': 'testuser',
  'email': 'test@example.com',
  'emailVerified': true,
  'createdAt': '2024-01-01T00:00:00.000Z',
  'updatedAt': '2024-01-01T00:00:00.000Z',
};

void main() {
  late _MockSecureStorage secure;
  late TokenStorageService storage;

  const key = 'bge_session_server-1';

  final persistedAt = DateTime.utc(2026, 1, 1);
  final confirmedExpiry = DateTime.utc(2026, 1, 8);
  final user = AuthUser.fromJson(_wireUser());

  /// Both clocks agree — the common case. Suites that need them to
  /// disagree call [StoredSession.canRestoreOffline] directly.
  bool restorable(StoredSession session, DateTime now) =>
      session.canRestoreOffline(correctedNowUtc: now, deviceNowUtc: now);

  /// A current (v2) payload with a server-confirmed expiry and a snapshot.
  String v2Payload({
    String? expiresAt = '2026-01-08T00:00:00.000Z',
    Object? userJson = const {},
  }) => jsonEncode({
    'v': 2,
    'token': 'tok-abc',
    'expires_at': expiresAt,
    'persisted_at': '2026-01-01T00:00:00.000Z',
    'user': userJson is Map && userJson.isEmpty ? _wireUser() : userJson,
  });

  /// The pre-#98 shape: token plus a client-fabricated expiry, no version,
  /// no snapshot.
  String v1Payload() => jsonEncode({
    'token': 'tok-abc',
    'expires_at': '2099-01-01T00:00:00.000Z',
  });

  setUp(() {
    secure = _MockSecureStorage();
    storage = TokenStorageService(serverId: 'server-1', storage: secure);
    when(
      () => secure.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(() => secure.delete(key: any(named: 'key'))).thenAnswer((_) async {});
  });

  group('session payload (#98)', () {
    test('round-trips token, confirmed expiry, persistedAt and user '
        'snapshot through a single key', () async {
      String? written;
      when(
        () => secure.write(
          key: key,
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        written = invocation.namedArguments[#value] as String?;
      });

      await storage.store(
        token: 'tok-abc',
        expiresAt: confirmedExpiry,
        persistedAt: persistedAt,
        user: user,
      );

      // One key, one write — store/clear atomicity is structural.
      verify(
        () => secure.write(
          key: key,
          value: any(named: 'value'),
        ),
      ).called(1);

      when(() => secure.read(key: key)).thenAnswer((_) async => written);
      final restored = await storage.retrieve();

      expect(restored, isNotNull);
      expect(restored!.token, 'tok-abc');
      expect(restored.expiresAt, confirmedExpiry);
      expect(restored.persistedAt, persistedAt);
      expect(restored.user?.id, 'user-1');
      expect(restored.user?.username, 'testuser');
      expect(restored.hasConfirmedExpiry, isTrue);
    });

    test('a null expiry round-trips as UNKNOWN, not expired — the token '
        'stays usable so the reconcile call can go out', () async {
      String? written;
      when(
        () => secure.write(
          key: key,
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        written = invocation.namedArguments[#value] as String?;
      });

      await storage.store(
        token: 'tok-abc',
        expiresAt: null,
        persistedAt: persistedAt,
        user: user,
      );

      when(() => secure.read(key: key)).thenAnswer((_) async => written);
      final restored = (await storage.retrieve())!;

      expect(restored.hasConfirmedExpiry, isFalse);
      // Unknown must not read as dead, or the TokenInterceptor would strip
      // the Authorization header from the very request that confirms it.
      expect(restored.isExpiredAt(DateTime.utc(2030)), isFalse);
      // …but unknown is still not good enough to enter the app on.
      expect(restorable(restored, DateTime.utc(2026, 1, 2)), isFalse);
    });
  });

  group('v1 payload compatibility', () {
    test('discards the v1 expiry — a fabricated value must never gate '
        'offline restore', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => v1Payload());

      final restored = (await storage.retrieve())!;

      expect(restored.token, 'tok-abc');
      // The v1 blob said 2099; we refuse to believe it because v1 cannot
      // distinguish a reconciled expiry from the old seven-day guess.
      expect(restored.expiresAt, isNull);
      expect(restored.hasConfirmedExpiry, isFalse);
      expect(restored.user, isNull);
      expect(restorable(restored, DateTime.utc(2026)), isFalse);
    });

    test('a v1 payload still yields a usable token', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => v1Payload());

      final restored = (await storage.retrieve())!;

      expect(restored.isExpiredAt(DateTime.utc(2030)), isFalse);
      expect(await storage.hasToken(), isTrue);
    });
  });

  group('decode resilience', () {
    test('a malformed user snapshot drops only the snapshot — the working '
        'token is not thrown away', () async {
      when(
        () => secure.read(key: key),
      ).thenAnswer((_) async => v2Payload(userJson: {'unexpected': 'shape'}));

      final restored = await storage.retrieve();

      expect(restored, isNotNull);
      expect(restored!.token, 'tok-abc');
      expect(restored.user, isNull);
      // Degrades to "no offline restore", not to a forced sign-out.
      expect(restorable(restored, DateTime.utc(2026, 1, 2)), isFalse);
      verifyNever(() => secure.delete(key: any(named: 'key')));
    });

    test('an undecodable payload clears the key and reports nothing '
        'stored', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => 'not json');

      expect(await storage.retrieve(), isNull);
      verify(() => secure.delete(key: key)).called(1);
    });
  });

  group('StoredSession.canRestoreOffline', () {
    StoredSession session({
      DateTime? expiresAt,
      AuthUser? snapshot,
      DateTime? writtenAt,
    }) => StoredSession(
      token: 'tok-abc',
      persistedAt: writtenAt ?? persistedAt,
      expiresAt: expiresAt,
      user: snapshot,
    );

    final duringSession = DateTime.utc(2026, 1, 2);

    test('eligible when confirmed, unexpired, snapshotted and the device '
        'clock has not moved backwards', () {
      expect(
        restorable(
          session(expiresAt: confirmedExpiry, snapshot: user),
          duringSession,
        ),
        isTrue,
      );
    });

    test('ineligible without a user snapshot — the per-(server, user) '
        'scope cannot activate without a real user id (#135)', () {
      expect(
        restorable(session(expiresAt: confirmedExpiry), duringSession),
        isFalse,
      );
    });

    test('ineligible without a server-confirmed expiry', () {
      expect(restorable(session(snapshot: user), duringSession), isFalse);
    });

    test('ineligible once the confirmed expiry has passed', () {
      expect(
        restorable(
          session(expiresAt: confirmedExpiry, snapshot: user),
          DateTime.utc(2026, 2, 1),
        ),
        isFalse,
      );
    });

    test('ineligible when the device clock precedes the write — neither '
        'expired nor unexpired is defensible then', () {
      final stored = session(
        expiresAt: confirmedExpiry,
        snapshot: user,
        writtenAt: DateTime.utc(2026, 6, 1),
      );

      expect(stored.isDeviceClockPlausibleAt(duringSession), isFalse);
      expect(restorable(stored, duringSession), isFalse);
    });

    test('a device lagging the server stays eligible — the plausibility '
        'guard reads the RAW device clock, so a corrected reading sitting '
        'ahead of it must not be mistaken for a backwards clock', () {
      // persistedAt was stamped from the device clock during an online
      // session. The corrected clock runs an hour ahead of this device.
      final stored = session(expiresAt: confirmedExpiry, snapshot: user);

      expect(
        stored.canRestoreOffline(
          correctedNowUtc: duringSession.add(const Duration(hours: 1)),
          deviceNowUtc: duringSession,
        ),
        isTrue,
      );
    });
  });

  group('sign-out latch (#37 / PR #99)', () {
    test('retrieve returns null after clear, even if the payload physically '
        'survives a failed delete', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => v2Payload());
      when(() => secure.delete(key: any(named: 'key')))
          .thenThrow(StateError('keychain unavailable'));

      // Material is present before sign-out.
      expect(await storage.retrieve(), isNotNull);

      // clear() latches first, then the delete throws.
      await expectLater(storage.clear(), throwsA(isA<StateError>()));

      // Despite the surviving payload, retrieve reports nothing — so
      // neither the interceptor's Authorization header nor getSession can
      // resurrect it, and no user snapshot leaks back either.
      expect(await storage.retrieve(), isNull);
      expect(await storage.hasToken(), isFalse);
    });

    test('retrieve returns null after a successful clear', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => v2Payload());

      await storage.clear();

      expect(await storage.retrieve(), isNull);
    });

    test('clearing deletes the ONE key holding both credential and user '
        'snapshot — a sign-out cannot leave PII behind', () async {
      await storage.clear();

      verify(() => secure.delete(key: key)).called(1);
      verifyNoMoreInteractions(secure);
    });

    test('storing new material lifts the latch (fresh sign-in supersedes '
        'the prior sign-out)', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => v2Payload());
      await storage.clear();
      expect(await storage.retrieve(), isNull);

      await storage.store(
        token: 'tok-abc',
        expiresAt: confirmedExpiry,
        persistedAt: persistedAt,
        user: user,
      );

      expect(await storage.retrieve(), isNotNull);
    });
  });
}
