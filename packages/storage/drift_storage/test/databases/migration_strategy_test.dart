import 'dart:io';

import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:storage_interface/storage_interface.dart';

import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/databases/migration_policy.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;

void main() {
  group('guardAgainstDowngrade', () {
    test('throws SchemaDowngradeError when the on-disk version is newer', () {
      expect(
        () => guardAgainstDowngrade(2, 1),
        throwsA(
          isA<SchemaDowngradeError>()
              .having((e) => e.onDisk, 'onDisk', 2)
              .having((e) => e.supported, 'supported', 1),
        ),
      );
    });

    test('does not throw for a forward upgrade (from < to)', () {
      expect(() => guardAgainstDowngrade(1, 2), returnsNormally);
    });

    test('does not throw when versions match (from == to)', () {
      expect(() => guardAgainstDowngrade(1, 1), returnsNormally);
    });
  });

  // These invoke each database's *real* onUpgrade callback directly, proving
  // the shared guard is actually wired into both migration strategies. Drift
  // itself routes downgrades through onUpgrade with from > to; we don't retest
  // that framework behaviour, only that our callback refuses it.
  group('ServerDatabase migration', () {
    test('onUpgrade refuses a downgrade', () async {
      final db = inMemoryServerDatabase();
      addTearDown(db.close);
      await expectLater(
        db.migration.onUpgrade(db.createMigrator(), 2, 1),
        throwsA(isA<SchemaDowngradeError>()),
      );
    });
  });

  group('MetaDatabase migration', () {
    test('onUpgrade refuses a downgrade', () async {
      final db = MetaDatabase.test(NativeDatabase.memory());
      addTearDown(db.close);
      await expectLater(
        db.migration.onUpgrade(db.createMigrator(), 2, 1),
        throwsA(isA<SchemaDowngradeError>()),
      );
    });
  });

  // #288: WAL is not supported by sqlite3-wasm, so the shared PRAGMA
  // block takes it as a parameter instead of asserting it for every
  // platform. File-backed rather than in-memory on purpose — a memory
  // database reports `journal_mode: memory` whatever it is asked for, so
  // it cannot tell the two branches apart.
  group('applyStandardPragmas journal mode (#288)', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('bge_wal_test');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    Future<String> journalModeOf(ServerDatabase db) async {
      final row = await db.customSelect('PRAGMA journal_mode;').getSingle();
      return (row.data.values.first as String).toLowerCase();
    }

    Future<bool> foreignKeysOn(ServerDatabase db) async {
      final row = await db.customSelect('PRAGMA foreign_keys;').getSingle();
      // SQLite reports this as 0/1; drift surfaces it as an int.
      return (row.data.values.first as int) == 1;
    }

    ServerDatabase openAt(String name, {required bool wal}) {
      final db = ServerDatabase(
        NativeDatabase(File('${dir.path}/$name')),
        enableWriteAheadLog: wal,
      );
      addTearDown(db.close);
      return db;
    }

    test('defaults to WAL, as the native executor needs', () async {
      final db = openAt('wal.db', wal: true);

      expect(await journalModeOf(db), 'wal');
      expect(await foreignKeysOn(db), isTrue);
    });

    test('enableWriteAheadLog: false leaves the journal mode alone — and still '
        'enforces foreign keys, which every platform honours', () async {
      final db = openAt('no_wal.db', wal: false);

      expect(await journalModeOf(db), isNot('wal'));
      expect(await foreignKeysOn(db), isTrue);
    });
  });
}
