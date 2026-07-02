# Drift schema migrations

How `drift_storage` versions and migrates its two databases — `ServerDatabase`
(one file per connected server) and `MetaDatabase` (one file per device). We
use drift's first-party tooling; we do **not** hand-write SQL snapshots or a
bespoke migration registry.

## Current state (v1)

Both databases are at `schemaVersion == 1`. There are **no forward
migrations** yet, so there is intentionally **no `*.steps.dart` file** and no
generated `test/drift/**` scaffold — `drift_dev make-migrations` only emits
those once a second schema version exists. Today `onUpgrade` does exactly one
thing: it refuses downgrades.

Committed, generated artefacts (never hand-edited):

- `drift_schemas/server/drift_schema_v1.json`
- `drift_schemas/meta/drift_schema_v1.json`

CI fails if either drifts from the live schema.

## Adding a schema change

1. Edit the table / database definitions.
2. Bump `schemaVersion` on the affected database class.
3. Refresh the committed snapshot(s): `melos run schema:dump`.
4. Generate the step-by-step scaffold + migration tests:
   `melos run schema:migrations`. This writes `<name>_database.steps.dart`
   next to the database and migration tests under `test/drift/`. **Commit
   these** — they are not produced by `melos run generate`, and CI does not
   regenerate them.
5. Dispatch the new step from `onUpgrade` using the generated `stepByStep`
   helper, keeping the downgrade guard first and running steps with foreign
   keys off inside a transaction:

   ```dart
   onUpgrade: (m, from, to) async {
     guardAgainstDowngrade(from, to);
     await customStatement('PRAGMA foreign_keys = OFF');
     await transaction(() async {
       await stepByStep(
         from1To2: (m, schema) async {
           // e.g. await m.addColumn(schema.games, schema.games.newField);
         },
       )(m, from, to);
     });
   },
   ```
6. Implement each `fromXToY` step, run `melos run test`, then commit.

## Invariants

**Downgrades are refused, never attempted.** Drift routes both directions
through `onUpgrade`. `guardAgainstDowngrade(from, to)` (in
`migration_policy.dart`) throws `SchemaDowngradeError` (defined in
`storage_interface`) when `from > to`. The storage layer throws; the **app
layer catches and localizes** — it refuses to open that database and shows a
localized message (suggested ARB key `storageSchemaDowngradeMessage`, integer
placeholders `{onDisk}` / `{supported}`). The error carries only version
numbers, never user-facing copy.

**Foreign keys are disabled during migrations.** SQLite cannot rewrite tables
with FK enforcement on, and `PRAGMA foreign_keys` is a no-op inside a
transaction. So any `onUpgrade` that runs steps sets `PRAGMA foreign_keys =
OFF` *before* opening the migration transaction. FKs are re-enabled in
`beforeOpen` via `applyStandardPragmas()`, which drift runs *after* migrations.
`beforeOpen` is the single place FKs are turned on — never enable them in
`onCreate` or `onUpgrade`.

**Migrations are pure and server-agnostic.** `ServerDatabase` has one file per
connected server, but every file shares one class, one schema, and one
migration path. Migration callbacks take only `(Migrator, schema)` /
`(from, to)` — never a `serverId` or any ambient / global state — so each
server's file migrates independently on open and cross-server contamination is
impossible by construction. `MetaDatabase` keeps its own separate schema
history and snapshot directory; the two never intersect.

**Runtime schema validation stays out of production code.**
`validateDatabaseSchema()` is a `drift_dev` API. Importing it into `lib/` would
promote `drift_dev` from a dev-dependency to a runtime dependency, so it is
**not** called in `beforeOpen`. The equivalent guarantee lives in the generated
`test/drift/**` schema tests (dev-only) plus the CI snapshot-freshness gate.
