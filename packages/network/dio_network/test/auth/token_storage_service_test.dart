import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:models/dto.dart';

import 'package:dio_network/src/auth/token_storage_service.dart';

import '../support/in_memory_session_tombstone_store.dart';

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
    storage = TokenStorageService(
      serverId: 'server-1',
      tombstones: InMemorySessionTombstoneStore(),
      storage: secure,
    );
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

  group('session tombstone (#356)', () {
    const serverId = 'server-1';

    late Map<String, String> keychain;
    late InMemorySessionTombstoneStore tombstones;
    late List<LogRecord> records;

    /// Runs ahead of the keychain operation, which a throw then stops.
    late Future<void> Function()? beforeWrite;
    late Future<void> Function()? beforeDelete;

    /// A fresh instance over the same keychain and marker is a cold start.
    TokenStorageService coldStart() => TokenStorageService(
      serverId: serverId,
      tombstones: tombstones,
      storage: secure,
    );

    Future<void> failDeletes() async => throw StateError('keychain delete');

    Future<void> storeToken(TokenStorageService service, String token) =>
        service.store(
          token: token,
          expiresAt: confirmedExpiry,
          persistedAt: persistedAt,
          user: user,
        );

    Iterable<LogRecord> warnings() => records.where(
      (record) =>
          record.level == Level.WARNING &&
          record.loggerName == 'bge.auth.token_storage',
    );

    setUp(() {
      keychain = {};
      tombstones = InMemorySessionTombstoneStore();
      beforeWrite = null;
      beforeDelete = null;

      when(() => secure.read(key: any(named: 'key')))
          .thenAnswer((invocation) async => keychain[key]);
      when(
        () => secure.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        await beforeWrite?.call();
        keychain[key] = invocation.namedArguments[#value] as String;
      });
      when(() => secure.delete(key: any(named: 'key'))).thenAnswer((_) async {
        await beforeDelete?.call();
        keychain.remove(key);
      });

      storage = coldStart();

      records = [];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = previousLevel;
        await subscription.cancel();
      });
    });

    test('a failed delete, then a cold start: nothing is read and the delete '
        'is retried', () async {
      keychain[key] = v2Payload();
      beforeDelete = failDeletes;
      await expectLater(storage.clear(), throwsA(isA<StateError>()));
      expect(keychain, contains(key), reason: 'the payload survived');

      beforeDelete = null;
      clearInteractions(secure);

      expect(await coldStart().retrieve(), isNull);
      verifyNever(() => secure.read(key: any(named: 'key')));
      verify(() => secure.delete(key: key)).called(1);
    });

    test('the retry succeeding removes the marker', () async {
      keychain[key] = v2Payload();
      tombstones.revoked.add(serverId);

      expect(await storage.retrieve(), isNull);

      expect(keychain, isNot(contains(key)));
      expect(tombstones.revoked, isEmpty);
    });

    test('the retry failing keeps the marker and still reports nothing '
        'stored', () async {
      keychain[key] = v2Payload();
      tombstones.revoked.add(serverId);
      beforeDelete = failDeletes;

      expect(await storage.retrieve(), isNull);
      expect(await storage.hasToken(), isFalse);

      expect(keychain, contains(key));
      expect(tombstones.revoked, contains(serverId));
      expect(warnings(), isNotEmpty);
      expect(await coldStart().retrieve(), isNull);
    });

    test('a clean clear leaves no marker behind', () async {
      keychain[key] = v2Payload();
      Set<String>? markedAtDelete;
      beforeDelete = () async {
        markedAtDelete = {...tombstones.revoked};
      };

      await storage.clear();

      expect(markedAtDelete, contains(serverId), reason: 'marker, then delete');
      expect(keychain, isNot(contains(key)));
      expect(tombstones.revoked, isEmpty);
    });

    test('clear still propagates a failed delete', () async {
      keychain[key] = v2Payload();
      beforeDelete = failDeletes;

      await expectLater(storage.clear(), throwsA(isA<StateError>()));

      expect(tombstones.revoked, contains(serverId));
    });

    test('a failed marker write does not stop the delete, and is '
        'logged', () async {
      keychain[key] = v2Payload();
      tombstones.failWrites = true;

      await storage.clear();

      expect(keychain, isNot(contains(key)));
      expect(warnings(), isNotEmpty);
    });

    test('a failed marker read falls back to the keychain and is '
        'logged', () async {
      keychain[key] = v2Payload();
      tombstones.failReads = true;

      final restored = await storage.retrieve();

      expect(restored?.token, 'tok-abc');
      expect(warnings(), hasLength(1));
    });

    group('a meta database that never answers', () {
      TokenStorageService impatient() => TokenStorageService(
        serverId: serverId,
        tombstones: tombstones,
        storage: secure,
        tombstoneTimeout: const Duration(milliseconds: 1),
      );

      test('does not stop clear from deleting and completing', () async {
        keychain[key] = v2Payload();
        tombstones.holdWrites = Completer<void>().future;

        await impatient().clear();

        expect(keychain, isNot(contains(key)));
        expect(warnings(), hasLength(1));
      });

      test('falls back to the keychain on a read, and is logged', () async {
        keychain[key] = v2Payload();
        tombstones.holdReads = Completer<void>().future;

        final restored = await impatient().retrieve();

        expect(restored?.token, 'tok-abc');
        expect(warnings(), hasLength(1));
      });

      test('does not stop store from completing', () async {
        tombstones.holdWrites = Completer<void>().future;

        await storeToken(impatient(), 'tok-new');

        expect(keychain, contains(key));
        expect(warnings(), hasLength(1));
      });

      test(
        'clear skips the removal after a marker write it gave up on',
        () async {
          keychain[key] = v2Payload();
          tombstones.holdWrites = Completer<void>().future;

          await impatient().clear();

          expect(
            warnings().where((r) => r.message.contains('remove the session')),
            isEmpty,
          );
        },
      );
    });

    test('store removes the marker, and a cold start reads the new '
        'payload', () async {
      keychain[key] = v2Payload();
      tombstones.revoked.add(serverId);

      await storeToken(storage, 'tok-new');

      expect(tombstones.revoked, isEmpty);
      expect((await coldStart().retrieve())?.token, 'tok-new');
    });

    test('a failed marker removal in store: this process keeps the session, '
        'the next cold start asks for a sign-in', () async {
      tombstones.revoked.add(serverId);
      tombstones.failWrites = true;

      await storeToken(storage, 'tok-new');

      expect((await storage.retrieve())?.token, 'tok-new');
      expect(warnings(), isNotEmpty);
      expect(tombstones.revoked, contains(serverId));
      expect(await coldStart().retrieve(), isNull);
    });

    test('a failed marker read is retried on the next read, which refuses a '
        'marked session', () async {
      keychain[key] = v2Payload();
      tombstones.revoked.add(serverId);
      tombstones.failReads = true;

      expect((await storage.retrieve())?.token, 'tok-abc');

      tombstones.failReads = false;

      expect(await storage.retrieve(), isNull);
      expect(keychain, isNot(contains(key)));
      expect(tombstones.revoked, isEmpty);
    });

    test('a marker that cannot be read stops being asked for', () async {
      keychain[key] = v2Payload();
      tombstones.failReads = true;

      for (var i = 0; i < 5; i++) {
        expect((await storage.retrieve())?.token, 'tok-abc');
      }

      expect(tombstones.reads, 3);
    });

    test('a retried marker read does not delete a session stored since the '
        'read failed', () async {
      tombstones.revoked.add(serverId);
      tombstones.failReads = true;
      tombstones.failWrites = true;

      await storeToken(storage, 'tok-new');

      tombstones.failReads = false;
      tombstones.failWrites = false;

      expect((await storage.retrieve())?.token, 'tok-new');
      expect(keychain, contains(key));
    });

    group('a store whose write fails after a failed marker read', () {
      Future<void> failWrites() async => throw StateError('keychain write');

      test('leaves the marker check to be retried, which refuses the session '
          'once the database recovers', () async {
        keychain[key] = v2Payload();
        tombstones.revoked.add(serverId);
        tombstones.failReads = true;
        beforeWrite = failWrites;

        await expectLater(
          storeToken(storage, 'tok-new'),
          throwsA(isA<StateError>()),
        );

        tombstones.failReads = false;

        expect(await storage.retrieve(), isNull);
        expect(keychain, isNot(contains(key)));
        expect(tombstones.revoked, isEmpty);
      });

      test('still counts towards the limit on failed reads', () async {
        keychain[key] = v2Payload();
        tombstones.failReads = true;
        beforeWrite = failWrites;

        for (var i = 0; i < 5; i++) {
          await expectLater(
            storeToken(storage, 'tok-new'),
            throwsA(isA<StateError>()),
          );
        }

        expect(tombstones.reads, 3);
      });

      /// Two stores waiting on one failed marker read, where [failing] is the
      /// one whose write throws, leaving a marker neither can remove.
      Future<void> overlapping({required String failing}) async {
        tombstones.revoked.add(serverId);
        tombstones.failReads = true;
        tombstones.failWrites = true;
        final releases = <String, Completer<void>>{
          'first': Completer<void>(),
          'second': Completer<void>(),
        };
        final order = ['first', 'second'].iterator;
        beforeWrite = () async {
          order.moveNext();
          final name = order.current;
          await releases[name]!.future;
          if (name == failing) throw StateError('keychain write');
        };

        final stores = Future.wait([
          storeToken(storage, 'tok-first'),
          storeToken(storage, 'tok-second'),
        ], eagerError: false).then<void>((_) {}, onError: (Object _) {});
        await pumpEventQueue();

        // Settle the failing write first, then the one that lands.
        final other = failing == 'first' ? 'second' : 'first';
        releases[failing]!.complete();
        await pumpEventQueue();
        releases[other]!.complete();
        await stores;

        tombstones.failReads = false;
        tombstones.failWrites = false;

        expect(await storage.retrieve(), isNotNull);
        expect(keychain, contains(key));
      }

      test('does not let a retried read delete what an overlapping store '
          'wrote, when the first write fails', () async {
        await overlapping(failing: 'first');
      });

      test('does not let a retried read delete what an overlapping store '
          'wrote, when the second write fails', () async {
        await overlapping(failing: 'second');
      });

      test('does not let a retried read delete what an earlier store wrote, '
          'when a later one fails', () async {
        tombstones.revoked.add(serverId);
        tombstones.failReads = true;
        tombstones.failWrites = true;
        final releaseSecond = Completer<void>();
        var writes = 0;
        beforeWrite = () async {
          writes += 1;
          if (writes == 2) {
            await releaseSecond.future;
            throw StateError('keychain write');
          }
        };

        final first = storeToken(storage, 'tok-first');
        final second = storeToken(storage, 'tok-second');
        await first;
        releaseSecond.complete();
        await expectLater(second, throwsA(isA<StateError>()));

        tombstones.failReads = false;
        tombstones.failWrites = false;

        expect((await storage.retrieve())?.token, 'tok-first');
        expect(keychain, contains(key));
      });

      test('a store that succeeds afterwards keeps its session', () async {
        tombstones.revoked.add(serverId);
        tombstones.failReads = true;
        tombstones.failWrites = true;
        beforeWrite = failWrites;
        await expectLater(
          storeToken(storage, 'tok-failed'),
          throwsA(isA<StateError>()),
        );

        beforeWrite = null;
        await storeToken(storage, 'tok-new');
        tombstones.failReads = false;
        tombstones.failWrites = false;

        expect((await storage.retrieve())?.token, 'tok-new');
        expect(keychain, contains(key));
      });
    });

    test('a clear landing during store stays latched', () async {
      final releaseWrite = Completer<void>();
      beforeWrite = () => releaseWrite.future;
      beforeDelete = failDeletes;

      final storing = storeToken(storage, 'tok-new');
      await pumpEventQueue();
      await expectLater(storage.clear(), throwsA(isA<StateError>()));
      releaseWrite.complete();
      await storing;

      expect(keychain, contains(key), reason: 'the delete failed');
      expect(await storage.retrieve(), isNull);
    });

    group('deleteAllStoredSessions', () {
      test('deletes every session and leaves other keychain entries', () async {
        when(secure.readAll).thenAnswer(
          (_) async => {
            'bge_session_a': 'x',
            'bge_session_b': 'y',
            'bge_meta_key': 'z',
          },
        );

        await TokenStorageService.deleteAllStoredSessions(storage: secure);

        verify(() => secure.delete(key: 'bge_session_a')).called(1);
        verify(() => secure.delete(key: 'bge_session_b')).called(1);
        verifyNever(() => secure.delete(key: 'bge_meta_key'));
      });
    });

    test('the marker is read once per process', () async {
      keychain[key] = v2Payload();

      await storage.retrieve();
      await storage.hasToken();
      await storeToken(storage, 'tok-new');
      await storage.retrieve();

      expect(tombstones.reads, 1);
    });

    test('a clear landing during store keeps the marker', () async {
      final releaseWrite = Completer<void>();
      beforeWrite = () => releaseWrite.future;
      beforeDelete = failDeletes;

      final storing = storeToken(storage, 'tok-new');
      await pumpEventQueue();
      verify(
        () => secure.write(
          key: key,
          value: any(named: 'value'),
        ),
      ).called(1);

      await expectLater(storage.clear(), throwsA(isA<StateError>()));
      releaseWrite.complete();
      await storing;

      expect(tombstones.revoked, contains(serverId));
      expect(await coldStart().retrieve(), isNull);
    });

    test(
      'a clear landing during the retried delete keeps its marker',
      () async {
        keychain[key] = v2Payload();
        tombstones.revoked.add(serverId);
        final releaseRetry = Completer<void>();
        var deletes = 0;
        beforeDelete = () async {
          deletes += 1;
          if (deletes == 1) return releaseRetry.future;
          throw StateError('keychain delete');
        };

        final retrieving = storage.retrieve();
        await pumpEventQueue();
        expect(deletes, 1, reason: 'the retry is in flight');

        await expectLater(storage.clear(), throwsA(isA<StateError>()));
        releaseRetry.complete();

        expect(await retrieving, isNull);
        expect(tombstones.revoked, contains(serverId));
      },
    );

    test('a store during the first marker check does not lose the new '
        'payload', () async {
      keychain[key] = v2Payload();
      tombstones.revoked.add(serverId);
      final releaseRead = Completer<void>();
      tombstones.holdReads = releaseRead.future;

      final retrieving = storage.retrieve();
      await pumpEventQueue();
      final storing = storeToken(storage, 'tok-new');
      await pumpEventQueue();

      releaseRead.complete();
      await storing;
      await retrieving;

      expect(keychain, contains(key));
      expect((await storage.retrieve())?.token, 'tok-new');
      expect(tombstones.revoked, isEmpty);
      tombstones.holdReads = null;
      expect((await coldStart().retrieve())?.token, 'tok-new');
    });

    test('a clear during the first marker check wins over a store waiting on '
        'it', () async {
      final releaseRead = Completer<void>();
      tombstones.holdReads = releaseRead.future;

      final storing = storeToken(storage, 'tok-new');
      await pumpEventQueue();
      await storage.clear();

      releaseRead.complete();
      await storing;

      verifyNever(
        () => secure.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
      expect(await storage.retrieve(), isNull);
      tombstones.holdReads = null;
      expect(await coldStart().hasToken(), isFalse);
    });
  });
}
