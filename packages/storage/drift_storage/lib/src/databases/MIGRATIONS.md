# Drift schema migrations

How `drift_storage` versions and migrates its two databases — `ServerDatabase`
(one file per connected server) and `MetaDatabase` (one file per device). We
use drift's first-party tooling; we do **not** hand-write SQL snapshots or a
bespoke migration registry.

## Current state

`ServerDatabase` is at `schemaVersion == 3`; `MetaDatabase` is at
`schemaVersion == 1`. The server database has real forward migrations, so the
generated `server_database.steps.dart` and the `test/drift/server/**` scaffold
(schema helpers + migration tests) exist and are **committed** — regenerate
them with `melos run schema:migrations` after every schema change. Both
databases build their strategy with `bgeMigrationStrategy()` (in
`migration_policy.dart`), which refuses downgrades ahead of the steps and
applies the standard PRAGMAs on open.

Server schema history:

- **v1 → v2 (#39):** additive `households.is_dirty` / `households.is_local_only`
  flags via `addColumn` with back-filled `false`.
- **v2 → v3 (#147):** user-scopes the sync queue — `sync_queue.user_id`
  (`TEXT NOT NULL`, no default) plus the `(user_id, status, created_at)` index
  replacing `(status, created_at)`. SQLite cannot ADD COLUMN a NOT NULL column
  without a default, and legacy rows are deliberately **dropped** rather than
  backfilled (attributing them to the migrating session's user would be
  wrong), so the step drops and recreates the table. `sync_queue` has no FK
  edges, so the FK-off wrapper question (#54) stays deferred.

Committed, generated artefacts (never hand-edited):

- `drift_schemas/server/drift_schema_v1.json` … `drift_schema_v3.json`
- `drift_schemas/meta/drift_schema_v1.json`

CI fails if the latest snapshot of either database drifts from the live
schema.

## Adding a schema change

1. Edit the table / database definitions.
2. Bump `schemaVersion` on the affected database class.
3. Refresh the committed snapshot(s): `melos run schema:dump`.
4. Generate the step-by-step scaffold + migration tests:
   `melos run schema:migrations`. This writes `<name>_database.steps.dart`
   next to the database and migration tests under `test/drift/`. **Commit
   these** — they are not produced by `melos run generate`, and CI does not
   regenerate them.
5. Extend the `steps:` closure passed to the shared factory — the factory
   keeps the downgrade guard ahead of it automatically. The shipped steps are
   hand-written `if (from < N && to >= N)` blocks against the live table
   definitions (the `to` bound matters: the schema verifier runs
   *intermediate* migrations, and an unbounded block would over-migrate past
   the requested target)
   (sufficient for additive columns and for FK-free table rebuilds); switching
   to the generated `stepByStep(...)` dispatcher remains an open option under
   #54 and becomes compelling with the first destructive migration of an
   FK-referenced table:

   ```dart
   @override
   MigrationStrategy get migration => bgeMigrationStrategy(
     steps: (Migrator m, int from, int to) async {
       if (from < N && to >= N) {
         // e.g. await m.addColumn(gamesTable, gamesTable.newField);
       }
     },
   );
   ```
6. Implement each version block, run `melos run test`, then commit.

> **Deferred to #54 — the FK-off + transaction wrapper.** Destructive migrations
> need to run with foreign keys off, inside a transaction. Where that wrapper
> lives — owned by `bgeMigrationStrategy` around `steps`, or written by the
> migration author — depends on whether drift's generated `stepByStep` already
> manages its own transaction and foreign-key handling. That is checked against
> drift's real behaviour when the first migration lands, not guessed now. Until
> then the factory does **not** wrap `steps`, and no hand-rolled wrapper should
> be added speculatively.

## Invariants

**Downgrades are refused, never attempted.** Drift routes both directions
through `onUpgrade`. `guardAgainstDowngrade(from, to)` (in
`migration_policy.dart`) throws `SchemaDowngradeError` (defined in
`storage_interface`) when `from > to`. The storage layer throws; the **app
layer catches and localizes** — it refuses to open that database and shows a
localized message (suggested ARB key `storageSchemaDowngradeMessage`, integer
placeholders `{onDisk}` / `{supported}`). The error carries only version
numbers, never user-facing copy.

**Foreign keys must be off during destructive migrations.** SQLite cannot
rewrite tables with FK enforcement on, and `PRAGMA foreign_keys` is a no-op
inside a transaction (so it has to be toggled outside one). FKs are re-enabled
in `beforeOpen` via `applyStandardPragmas()`, which drift runs *after*
migrations — `beforeOpen` is the single place FKs are turned on; never enable
them in `onCreate` or `onUpgrade`. The exact placement of the `foreign_keys =
OFF` + `transaction(...)` wrapper around migration steps is deferred to #54 (see
the note under "Adding a schema change"); until a real migration exists,
`bgeMigrationStrategy` does not wrap `steps` and nothing should hand-roll it.

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

## Deferred items

- **#54 — step-by-step harness activation.** The `stepByStep` dispatcher, the
  generated `test/drift/**` migration tests, and the FK-off + transaction
  wrapper decision above all land with the first real schema change.
- **#55 — app-layer downgrade handling.** Catching `SchemaDowngradeError`,
  refusing to open the affected database, and rendering the localized
  `storageSchemaDowngradeMessage` are the app layer's responsibility, pending
  the Phase 2 open/close path.
