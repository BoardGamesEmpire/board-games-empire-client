import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/household_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

// ── Fixtures ───────────────────────────────────────────────────────────────────

const _kUserId = 'user-abc';
const _kOtherUserId = 'user-other';

Future<void> _seedHousehold(
  ServerDatabase db, {
  required String id,
  String name = 'Test Household',
  DateTime? deletedAt,
  DateTime? createdAt,
}) async {
  final now = createdAt ?? DateTime.now().toUtc();
  await db
      .into(db.householdsTable)
      .insert(
        HouseholdsTableCompanion.insert(
          id: id,
          name: name,
          deletedAt: Value(deletedAt),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _seedMember(
  ServerDatabase db, {
  required String id,
  required String userId,
  required String householdId,
  String? roleName,
}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.householdMembersTable)
      .insert(
        HouseholdMembersTableCompanion.insert(
          id: id,
          userId: userId,
          householdId: householdId,
          roleName: Value(roleName),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late ServerDatabase db;
  late HouseholdRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    final clock = FixedClockService(DateTime.utc(2024, 1, 15, 10, 30));
    repo = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: SyncQueueRepositoryImpl(db, clock, userId: _kUserId),
      clock: clock,
    );
  });

  tearDown(() async => db.close());

  group('HouseholdRepositoryImpl', () {
    group('getHouseholds()', () {
      test('returns only households the current user is a member of', () async {
        await _seedHousehold(db, id: 'h-1', name: 'Mine');
        await _seedHousehold(db, id: 'h-2', name: 'Not Mine');
        await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kOtherUserId,
          householdId: 'h-2',
        );

        final households = await repo.getHouseholds();
        expect(households, hasLength(1));
        expect(households.single.id, equals('h-1'));
      });

      test('excludes tombstoned households', () async {
        final now = DateTime.now().toUtc();
        await _seedHousehold(
          db,
          id: 'h-1',
          name: 'Mine (deleted)',
          deletedAt: now,
        );
        await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');

        expect(await repo.getHouseholds(), isEmpty);
      });

      test(
        'returns empty when user is not a member of any household',
        () async {
          await _seedHousehold(db, id: 'h-1');
          // No membership for _kUserId.
          expect(await repo.getHouseholds(), isEmpty);
        },
      );

      // #269 D3. There was no ORDER BY here at all, so the list rendered in
      // SQLite's natural order and could reshuffle on any upsert — a
      // list-screen bug independent of which order wins.
      test('orders by name, case-insensitively', () async {
        await _seedHousehold(db, id: 'h-1', name: 'banana');
        await _seedHousehold(db, id: 'h-2', name: 'Apple');
        await _seedHousehold(db, id: 'h-3', name: 'Cherry');
        for (final (i, h) in ['h-1', 'h-2', 'h-3'].indexed) {
          await _seedMember(db, id: 'm-$i', userId: _kUserId, householdId: h);
        }

        final names = (await repo.getHouseholds()).map((h) => h.name).toList();
        // Not ['Apple', 'Cherry', 'banana'] — that is what a raw byte-wise
        // sort gives, and it reads as broken to anyone scanning the list.
        expect(names, equals(['Apple', 'banana', 'Cherry']));
      });

      test('breaks a name tie on createdAt, oldest first', () async {
        // The tiebreak is deliberately NOT the id: a cuid2 sorts by an
        // opaque token nobody can predict, which is arbitrary order wearing
        // determinism (#269 D3).
        await _seedHousehold(
          db,
          id: 'h-newer',
          name: 'Game Night',
          createdAt: DateTime.utc(2026, 3),
        );
        await _seedHousehold(
          db,
          id: 'h-older',
          name: 'Game Night',
          createdAt: DateTime.utc(2026),
        );
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-newer',
        );
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kUserId,
          householdId: 'h-older',
        );

        final ids = (await repo.getHouseholds()).map((h) => h.id).toList();
        expect(ids, equals(['h-older', 'h-newer']));
      });
    });

    group('getHousehold()', () {
      test('returns the household when the user is a member', () async {
        await _seedHousehold(db, id: 'h-1', name: 'Mine');
        await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');

        final h = await repo.getHousehold('h-1');
        expect(h, isNotNull);
        expect(h!.name, equals('Mine'));
      });

      test('returns null when the user is not a member', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kOtherUserId,
          householdId: 'h-1',
        );

        expect(await repo.getHousehold('h-1'), isNull);
      });

      test('returns null when the household does not exist', () async {
        expect(await repo.getHousehold('nonexistent'), isNull);
      });

      test(
        'returns null for a tombstoned household even when user is a member',
        () async {
          final now = DateTime.now().toUtc();
          await _seedHousehold(db, id: 'h-1', name: 'Removed', deletedAt: now);
          await _seedMember(
            db,
            id: 'm-1',
            userId: _kUserId,
            householdId: 'h-1',
          );

          expect(await repo.getHousehold('h-1'), isNull);
        },
      );
    });

    group('getMembers()', () {
      test('returns all members when the current user is a member of the household', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
          roleName: 'HouseholdOwner',
        );
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kOtherUserId,
          householdId: 'h-1',
          roleName: 'HouseholdMember',
        );

        final members = await repo.getMembers('h-1');
        expect(members, hasLength(2));
        expect(
          members.map((m) => m.userId),
          unorderedEquals([_kUserId, _kOtherUserId]),
        );
      });

      test(
        'returns empty when the current user is NOT a member of the household '
        '(boundary enforcement — see class doc TODO for the planned '
        'visibility-field exception)',
        () async {
          await _seedHousehold(db, id: 'h-1');
          await _seedMember(
            db,
            id: 'm-other',
            userId: _kOtherUserId,
            householdId: 'h-1',
            roleName: 'HouseholdOwner',
          );
          await _seedMember(
            db,
            id: 'm-third',
            userId: 'user-third',
            householdId: 'h-1',
          );

          expect(await repo.getMembers('h-1'), isEmpty);
        },
      );

      test('returns empty when the household has no rows at all', () async {
        expect(await repo.getMembers('nonexistent'), isEmpty);
      });

      test('returns empty for a tombstoned household even when the current user is a member', () async {
        final now = DateTime.now().toUtc();
        await _seedHousehold(db, id: 'h-1', name: 'Removed', deletedAt: now);
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
          roleName: 'HouseholdOwner',
        );
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kOtherUserId,
          householdId: 'h-1',
        );

        expect(await repo.getMembers('h-1'), isEmpty);
      });
    });

    group('getCurrentUserMember()', () {
      test(
        'returns the member record for the current user in the household',
        () async {
          await _seedHousehold(db, id: 'h-1');
          await _seedMember(
            db,
            id: 'm-1',
            userId: _kUserId,
            householdId: 'h-1',
            roleName: 'HouseholdOwner',
          );
          await _seedMember(
            db,
            id: 'm-2',
            userId: _kOtherUserId,
            householdId: 'h-1',
            roleName: 'HouseholdMember',
          );

          final me = await repo.getCurrentUserMember('h-1');
          expect(me, isNotNull);
          expect(me!.id, equals('m-1'));
          expect(me.userId, equals(_kUserId));
          expect(me.role, equals(HouseholdRole.householdOwner));
        },
      );

      test('returns null when the user is not a member', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedMember(
          db,
          id: 'm-other',
          userId: _kOtherUserId,
          householdId: 'h-1',
        );

        expect(await repo.getCurrentUserMember('h-1'), isNull);
      });

      test('returns null when the household does not exist', () async {
        expect(await repo.getCurrentUserMember('nonexistent'), isNull);
      });
    });

    group('cacheHousehold()', () {
      test('upserts a household', () async {
        final now = DateTime.now().toUtc();
        final h = Household(
          id: 'h-1',
          name: 'Cached',
          createdAt: now,
          updatedAt: now,
        );

        await repo.cacheHousehold(h);

        // Make the user a member so getHousehold can see it through
        // the inner-join filter.
        await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');

        final retrieved = await repo.getHousehold('h-1');
        expect(retrieved, isNotNull);
        expect(retrieved!.name, equals('Cached'));
      });
    });

    group('cacheMember() / cacheMembers()', () {
      test('cacheMember persists a single row and reads it back', () async {
        await _seedHousehold(db, id: 'h-1');
        final now = DateTime.now().toUtc();

        await repo.cacheMember(
          HouseholdMember(
            id: 'm-1',
            userId: _kUserId,
            householdId: 'h-1',
            role: HouseholdRole.householdOwner,
            showAllGames: true,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final me = await repo.getCurrentUserMember('h-1');
        expect(me, isNotNull);
        expect(me!.id, equals('m-1'));
        expect(me.role, equals(HouseholdRole.householdOwner));
        expect(me.showAllGames, isTrue);
      });

      test(
        'cacheMember upserts on conflicting id (second cacheMember wins)',
        () async {
          await _seedHousehold(db, id: 'h-1');
          final now = DateTime.now().toUtc();

          await repo.cacheMember(
            HouseholdMember(
              id: 'm-1',
              userId: _kUserId,
              householdId: 'h-1',
              role: HouseholdRole.householdMember,
              createdAt: now,
              updatedAt: now,
            ),
          );

          // Promote the same member to owner. id, userId,
          // householdId are unchanged; only role and showAllGames
          // differ. The upsert path must pick up the new values.
          await repo.cacheMember(
            HouseholdMember(
              id: 'm-1',
              userId: _kUserId,
              householdId: 'h-1',
              role: HouseholdRole.householdOwner,
              showAllGames: true,
              createdAt: now,
              updatedAt: now,
            ),
          );

          final me = await repo.getCurrentUserMember('h-1');
          expect(me, isNotNull);
          expect(me!.role, equals(HouseholdRole.householdOwner));
          expect(me.showAllGames, isTrue);
        },
      );

      test(
        'cacheMember round-trips every HouseholdRole through the wire bridge',
        () async {
          // The repo persists `role` via the static _encodeRole
          // switch (HouseholdRole -> 'HouseholdOwner' /
          // 'HouseholdAdmin' / 'HouseholdMember' / 'HouseholdGuest'
          // / 'Unknown') and reads it back via _decodeRole. Both
          // must agree across every variant.
          //
          // Note on HouseholdRole.unknown: per the _encodeRole
          // dartdoc, the bridge collapses unknown server-defined
          // role names to 'Unknown' on the way out, so the original
          // custom name from the server is intentionally lost in
          // round-trip. The test still covers `unknown` because
          // _decodeRole('Unknown') is the inverse and a regression
          // there would silently demote unknown roles to null.
          await _seedHousehold(db, id: 'h-1');
          final now = DateTime.now().toUtc();

          for (final role in HouseholdRole.values) {
            // Fresh user id per role so we don't collide with the
            // (householdId, userId) unique index.
            final userId = 'user-${role.name}';
            await repo.cacheMember(
              HouseholdMember(
                id: 'm-${role.name}',
                userId: userId,
                householdId: 'h-1',
                role: role,
                createdAt: now,
                updatedAt: now,
              ),
            );
          }

          // Make the current user a member so getMembers will
          // surface the full roster through the boundary gate.
          await repo.cacheMember(
            HouseholdMember(
              id: 'm-mine',
              userId: _kUserId,
              householdId: 'h-1',
              createdAt: now,
              updatedAt: now,
            ),
          );

          final members = await repo.getMembers('h-1');
          // 5 role variants + the current user's row = 6 rows.
          expect(members, hasLength(HouseholdRole.values.length + 1));

          for (final role in HouseholdRole.values) {
            final m = members.firstWhere(
              (m) => m.userId == 'user-${role.name}',
            );
            expect(
              m.role,
              equals(role),
              reason: 'role round-trip failed for HouseholdRole.${role.name}',
            );
          }
        },
      );

      test('cacheMember stores null role and reads it back as null', () async {
        // Role is nullable in the model (e.g., a transient
        // invitee with no role pinned yet). _encodeRole and
        // _decodeRole both short-circuit on null without touching
        // the 'Unknown' bridge.
        await _seedHousehold(db, id: 'h-1');
        final now = DateTime.now().toUtc();

        await repo.cacheMember(
          HouseholdMember(
            id: 'm-1',
            userId: _kUserId,
            householdId: 'h-1',
            createdAt: now,
            updatedAt: now,
          ),
        );

        final me = await repo.getCurrentUserMember('h-1');
        expect(me, isNotNull);
        expect(me!.role, isNull);
      });

      test('cacheMembers persists multiple rows in one batch', () async {
        await _seedHousehold(db, id: 'h-1');
        final now = DateTime.now().toUtc();

        await repo.cacheMembers([
          HouseholdMember(
            id: 'm-mine',
            userId: _kUserId,
            householdId: 'h-1',
            role: HouseholdRole.householdOwner,
            createdAt: now,
            updatedAt: now,
          ),
          HouseholdMember(
            id: 'm-other',
            userId: _kOtherUserId,
            householdId: 'h-1',
            role: HouseholdRole.householdMember,
            createdAt: now,
            updatedAt: now,
          ),
          HouseholdMember(
            id: 'm-third',
            userId: 'user-third',
            householdId: 'h-1',
            role: HouseholdRole.householdGuest,
            createdAt: now,
            updatedAt: now,
          ),
        ]);

        final members = await repo.getMembers('h-1');
        expect(members, hasLength(3));
        expect(
          members.map((m) => m.userId),
          unorderedEquals([_kUserId, _kOtherUserId, 'user-third']),
        );
      });

      test(
        'cacheMembers upserts mixed new + existing rows on conflict',
        () async {
          // Realistic flow: server returns an initial roster, then a
          // corrected version where the existing m-mine's role
          // changed AND a new m-third was added. The batch must
          // apply both writes correctly under the
          // (householdId, userId) unique index.
          await _seedHousehold(db, id: 'h-1');
          final now = DateTime.now().toUtc();

          await repo.cacheMember(
            HouseholdMember(
              id: 'm-mine',
              userId: _kUserId,
              householdId: 'h-1',
              role: HouseholdRole.householdMember,
              createdAt: now,
              updatedAt: now,
            ),
          );

          await repo.cacheMembers([
            HouseholdMember(
              id: 'm-mine',
              userId: _kUserId,
              householdId: 'h-1',
              role: HouseholdRole.householdOwner,
              createdAt: now,
              updatedAt: now,
            ),
            HouseholdMember(
              id: 'm-third',
              userId: 'user-third',
              householdId: 'h-1',
              role: HouseholdRole.householdGuest,
              createdAt: now,
              updatedAt: now,
            ),
          ]);

          final members = await repo.getMembers('h-1');
          expect(members, hasLength(2));

          final me = members.firstWhere((m) => m.userId == _kUserId);
          expect(me.role, equals(HouseholdRole.householdOwner));

          final third = members.firstWhere((m) => m.userId == 'user-third');
          expect(third.role, equals(HouseholdRole.householdGuest));
        },
      );

      test('cacheMember replaces a synthesized owner row when the server row '
          'carries a different id (#267 D4)', () async {
        // Same collision as the batch writer below, through the
        // single-row path. `cacheMember` is the writer #122's
        // membership sync will reach for, so it must resolve the
        // (householdId, userId) index too — not the primary key.
        await _seedHousehold(db, id: 'h-1');
        final now = DateTime.now().toUtc();

        await _seedMember(
          db,
          id: 'local-owner-cuid',
          userId: _kUserId,
          householdId: 'h-1',
          roleName: 'HouseholdOwner',
        );

        await repo.cacheMember(
          HouseholdMember(
            id: 'server-member-id',
            userId: _kUserId,
            householdId: 'h-1',
            role: HouseholdRole.householdOwner,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final members = await repo.getMembers('h-1');
        expect(members, hasLength(1));
        expect(members.single.id, equals('server-member-id'));
      });

      test('cacheMembers replaces a synthesized owner row when the server row '
          'carries a different id (#267 D4)', () async {
        // The create flow synthesizes an owner member row with a
        // CLIENT-generated id, and reconcileCreatedHousehold
        // deliberately keeps that id (the authoritative one is #122's
        // job). So the server's row for the same (householdId, userId)
        // arrives under a DIFFERENT id — which collides with the
        // (householdId, userId) unique index, not with the primary key.
        // Resolving conflicts on the primary key alone makes this an
        // insert failure and kills the hydrate on the common path.
        await _seedHousehold(db, id: 'h-1');
        final now = DateTime.now().toUtc();

        await _seedMember(
          db,
          id: 'local-owner-cuid',
          userId: _kUserId,
          householdId: 'h-1',
          roleName: 'HouseholdOwner',
        );

        await repo.cacheMembers([
          HouseholdMember(
            id: 'server-member-id',
            userId: _kUserId,
            householdId: 'h-1',
            role: HouseholdRole.householdOwner,
            createdAt: now,
            updatedAt: now,
          ),
        ]);

        final members = await repo.getMembers('h-1');
        expect(members, hasLength(1));
        expect(members.single.id, equals('server-member-id'));
        expect(members.single.role, equals(HouseholdRole.householdOwner));
      });

      test('cacheMember is user-agnostic (caches a row for a different user, '
          'boundary gate prevents read leakage)', () async {
        // The repo is scoped to _kUserId, but the cache writers
        // accept payloads the server has already auth-filtered.
        // A member row for another user can legitimately land in
        // the local cache (e.g., friend-graph queries) — the
        // read-side boundary in _membersQuery is what prevents
        // non-members from seeing it. This test pins both halves
        // of that design: the write is accepted, the read is
        // gated.
        await _seedHousehold(db, id: 'h-1');
        final now = DateTime.now().toUtc();

        await repo.cacheMember(
          HouseholdMember(
            id: 'm-other',
            userId: _kOtherUserId,
            householdId: 'h-1',
            role: HouseholdRole.householdOwner,
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Boundary gate fires — no row for _kUserId means the
        // roster is invisible through the public read API.
        expect(await repo.getMembers('h-1'), isEmpty);
        expect(await repo.getCurrentUserMember('h-1'), isNull);

        // But the row IS present in the raw cache, ready to be
        // unlocked when _kUserId joins.
        final rawRows = await db.select(db.householdMembersTable).get();
        expect(rawRows, hasLength(1));
        expect(rawRows.single.userId, equals(_kOtherUserId));
        expect(rawRows.single.roleName, equals('HouseholdOwner'));
      });
    });

    group('watchHouseholds()', () {
      test('emits only households the user is a member of', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedHousehold(db, id: 'h-2');
        await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kOtherUserId,
          householdId: 'h-2',
        );

        await expectLater(repo.watchHouseholds().take(1), emits(hasLength(1)));
      });

      test('excludes tombstoned households', () async {
        final now = DateTime.now().toUtc();
        await _seedHousehold(db, id: 'h-1', deletedAt: now);
        await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');

        await expectLater(repo.watchHouseholds().take(1), emits(isEmpty));
      });

      // The list screen's reactivity claim, end to end (#269): "create
      // writes locally, so the list updates with no refetch and no manual
      // invalidation". Every other watch test seeds rows through the table
      // directly, which exercises drift's stream but not the path the
      // create FAB actually takes — the transactional write plus enqueue.
      test('a local create reaches an open watch, with no refetch', () async {
        final arrived = expectLater(
          repo.watchHouseholds(),
          emitsThrough(
            predicate<List<Household>>(
              (households) => households.any(
                (h) => h.name == 'Sunday Crew' && h.isLocalOnly,
              ),
              'contains the locally-created household, flagged local-only',
            ),
          ),
        );

        await repo.create(name: 'Sunday Crew');

        await arrived;
      });

      // Same order as getHouseholds() — they share one selectable, and a
      // screen that reads the stream must not disagree with a screen that
      // reads the future (#269 D3).
      test('emits in the same order getHouseholds() returns', () async {
        await _seedHousehold(db, id: 'h-1', name: 'zulu');
        await _seedHousehold(db, id: 'h-2', name: 'Alpha');
        await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');
        await _seedMember(db, id: 'm-2', userId: _kUserId, householdId: 'h-2');

        await expectLater(
          repo.watchHouseholds().take(1),
          emits(
            isA<List<Household>>().having(
              (l) => l.map((h) => h.name).toList(),
              'names',
              equals(['Alpha', 'zulu']),
            ),
          ),
        );
      });
    });

    group('watchMembers()', () {
      test(
        'emits an empty list when the current user is not a member',
        () async {
          await _seedHousehold(db, id: 'h-1');
          await _seedMember(
            db,
            id: 'm-other',
            userId: _kOtherUserId,
            householdId: 'h-1',
          );

          await expectLater(repo.watchMembers('h-1').take(1), emits(isEmpty));
        },
      );

      test(
        'emits the full member list when the current user is a member',
        () async {
          await _seedHousehold(db, id: 'h-1');
          await _seedMember(
            db,
            id: 'm-1',
            userId: _kUserId,
            householdId: 'h-1',
            roleName: 'HouseholdOwner',
          );
          await _seedMember(
            db,
            id: 'm-2',
            userId: _kOtherUserId,
            householdId: 'h-1',
            roleName: 'HouseholdMember',
          );

          await expectLater(
            repo.watchMembers('h-1').take(1),
            emits(hasLength(2)),
          );
        },
      );

      test('emits an empty list for a tombstoned household even when the current user is a member', () async {
        final now = DateTime.now().toUtc();
        await _seedHousehold(db, id: 'h-1', name: 'Removed', deletedAt: now);
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
          roleName: 'HouseholdOwner',
        );
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kOtherUserId,
          householdId: 'h-1',
        );

        await expectLater(repo.watchMembers('h-1').take(1), emits(isEmpty));
      });

      test(
        'transitions from empty to full list when the current user joins',
        () async {
          // Reactive form of the boundary check: the watch stream
          // updates automatically when the membership changes.
          // Initial state: only _kOtherUserId is a member, so the
          // current user sees empty. After _kUserId joins, the next
          // emission contains both members.
          await _seedHousehold(db, id: 'h-1');
          await _seedMember(
            db,
            id: 'm-other',
            userId: _kOtherUserId,
            householdId: 'h-1',
            roleName: 'HouseholdOwner',
          );

          final futureEmissions = repo.watchMembers('h-1').take(2).toList();
          await pumpEventQueue();

          await _seedMember(
            db,
            id: 'm-mine',
            userId: _kUserId,
            householdId: 'h-1',
            roleName: 'HouseholdMember',
          );

          final emissions = await futureEmissions.timeout(
            const Duration(seconds: 5),
          );
          expect(emissions, hasLength(2));
          expect(emissions[0], isEmpty);
          expect(emissions[1], hasLength(2));
          expect(
            emissions[1].map((m) => m.userId),
            unorderedEquals([_kUserId, _kOtherUserId]),
          );
        },
      );
    });
  });
}
