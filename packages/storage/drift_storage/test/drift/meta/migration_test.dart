import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = MetaDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  // Data-integrity coverage for v1 → v2 (#356): the step adds a nullable
  // `server_configs.session_revoked_at` via `addColumn`. A registered server
  // must keep every value it had and read the new column as null, which the
  // session store reads as not revoked.
  //
  // Two rows, so the nullable columns the step does not touch are covered
  // both set and unset. Timestamps are opaque strings here:
  // `store_date_time_values_as_text: true` means Drift persists them as
  // text, and this step neither reads nor rewrites them — they must survive
  // byte-for-byte. `device_preferences` and `notification_summaries` are
  // untouched by this step and stay empty.
  test('migration from v1 to v2 adds an empty session_revoked_at and '
      'preserves server_configs rows', () async {
    const at = '2024-01-15T10:30:00.000Z';
    const later = '2024-01-16T09:00:00.000Z';

    final oldServerConfigsData = <v1.ServerConfigsData>[
      const v1.ServerConfigsData(
        id: 'sc_v1_1',
        bgeServerId: 'bge-v1-1',
        displayName: 'Home server',
        serverUrl: 'https://home.example.com',
        connectionState: 'Active',
        cachedIdentityJson: '{"serverId":"bge-v1-1"}',
        lastIdentityFetchedAt: at,
        lastActiveAt: later,
        backgroundingTimeoutSeconds: 90,
        metadata: '{"colour":"teal"}',
        createdAt: at,
        updatedAt: later,
      ),
      const v1.ServerConfigsData(
        id: 'sc_v1_2',
        bgeServerId: 'bge-v1-2',
        displayName: 'Club server',
        serverUrl: 'https://club.example.com',
        connectionState: 'Disconnected',
        cachedIdentityJson: '{"serverId":"bge-v1-2"}',
        lastIdentityFetchedAt: at,
        metadata: '{}',
        createdAt: at,
        updatedAt: at,
      ),
    ];
    // Same rows, with the new column null.
    final expectedNewServerConfigsData = <v2.ServerConfigsData>[
      const v2.ServerConfigsData(
        id: 'sc_v1_1',
        bgeServerId: 'bge-v1-1',
        displayName: 'Home server',
        serverUrl: 'https://home.example.com',
        connectionState: 'Active',
        cachedIdentityJson: '{"serverId":"bge-v1-1"}',
        lastIdentityFetchedAt: at,
        lastActiveAt: later,
        backgroundingTimeoutSeconds: 90,
        metadata: '{"colour":"teal"}',
        createdAt: at,
        updatedAt: later,
        sessionRevokedAt: null,
      ),
      const v2.ServerConfigsData(
        id: 'sc_v1_2',
        bgeServerId: 'bge-v1-2',
        displayName: 'Club server',
        serverUrl: 'https://club.example.com',
        connectionState: 'Disconnected',
        cachedIdentityJson: '{"serverId":"bge-v1-2"}',
        lastIdentityFetchedAt: at,
        metadata: '{}',
        createdAt: at,
        updatedAt: at,
        sessionRevokedAt: null,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 1,
      newVersion: 2,
      createOld: v1.DatabaseAtV1.new,
      createNew: v2.DatabaseAtV2.new,
      openTestedDatabase: MetaDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.serverConfigs, oldServerConfigsData);
      },
      validateItems: (newDb) async {
        expect(
          await newDb.select(newDb.serverConfigs).get(),
          expectedNewServerConfigsData,
        );
        expect(await newDb.select(newDb.devicePreferences).get(), isEmpty);
        expect(await newDb.select(newDb.notificationSummaries).get(), isEmpty);
      },
    );
  });
}
