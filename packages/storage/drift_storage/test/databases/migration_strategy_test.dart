import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:storage_interface/storage_interface.dart';

import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/databases/migration_policy.dart';
import 'package:drift_storage/src/databases/server_database.dart';

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
      final db = ServerDatabase.memory();
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
}
