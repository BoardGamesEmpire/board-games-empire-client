import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../tables/server_config_table.dart';
import 'package:flutter/foundation.dart';

part 'meta_database.g.dart';

@DriftDatabase(tables: [ServerConfigs])
class MetaDatabase extends _$MetaDatabase {
  MetaDatabase() : super(_openConnection());

  @visibleForTesting
  MetaDatabase.test(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // Future migrations will be handled here
      },
    );
  }

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final appDir = await getApplicationSupportDirectory();
      final metaDir = Directory(p.join(appDir.path, 'meta'));

      if (!await metaDir.exists()) {
        await metaDir.create(recursive: true);
      }

      final dbFile = File(p.join(metaDir.path, 'servers.db'));
      return NativeDatabase(dbFile);
    });
  }
}
