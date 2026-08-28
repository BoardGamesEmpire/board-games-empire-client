# web_storage

The web half of the Board Games Empire data layer: a drift/wasm
`QueryExecutor` and the install path that registers a `ServerDatabase` over
it (#288, designed in #63).

This package supplies an **executor and nothing more**. The databases and all
seven repositories are shared, platform-neutral code in `drift_storage`
(`drift_storage.dart`, split out by #287); native pairs them with the
encrypted SQLCipher executor in `drift_storage_native.dart`, and web pairs
them with `WebWasmExecutorFactory` here. There is no second implementation of
any query.

## Responsibilities

- **`WebWasmExecutorFactory`** — opens a drift/wasm database via
  `WasmDatabase.open`, letting drift pick the best storage implementation the
  browser offers (OPFS, then IndexedDB, then in-memory) and reporting which
  one it got.
- **`WebStoragePersistence`** — classifies that choice as `durable`,
  `unsafe` or `ephemeral`, so a degraded browser is a fact the app can act on
  rather than a silent loss of persistence.
- **`WebStorageInstaller`** — mirrors `StorageScopeInstaller`'s role on
  native: opens the database and registers it into the web server scope.

## No at-rest encryption on web (#63)

Deliberate, and documented at the point the executor is built
(`wasm_executor_factory.dart`) as well as here. The browser origin sandbox is
the security boundary: any key the page can read, page-injected JavaScript can
read too, and OPFS is already origin-sandboxed. This diverges from #16, which
encrypts every native database with SQLCipher. Revisit only if the threat model
changes — a shared-device deployment where the browser profile is not trusted.

Note that drift publishes `sqlite3mc.wasm` (the encrypted build) alongside the
plain `sqlite3.wasm`; `tool/fetch_web_assets.dart` fetches the plain one on
purpose.

## WAL is off on web

`ServerDatabase` takes `enableWriteAheadLog`, and this package passes `false`:
sqlite3-wasm does not support WAL journalling. See the platform note on
`BgeMigrationDefaults.applyStandardPragmas` in `drift_storage`.

## Required assets

The wasm executor needs two files served beside the app:

- `sqlite3.wasm`
- `drift_worker.js`

Both are fetched — not committed — by `melos run web:assets`, which takes them
from the drift release matching the resolved `drift` version in `pubspec.lock`,
so the worker can never drift out of step with the package. Run it once before
`melos run web` or any browser test in this package. See
`tool/fetch_web_assets.dart`.

## Tests

This package's suites are split by platform, and each file says which one it
runs on:

- `@TestOn('browser')` — everything that touches the executor: the real
  drift/wasm round-trip through a repository, the OPFS-unavailable fallback,
  the persistence classification, and the installer. Run with
  `melos run test:web` (`flutter test --platform chrome`); needs the assets
  above.
- `@TestOn('vm')` — the platform-boundary guard only. It reads this package's
  `lib/` as *text* and never imports it, which is what lets it run on the VM.

That split is forced, not stylistic: `package:drift/wasm.dart` reaches
`dart:js_interop`, so a VM suite cannot import anything in `lib/` — not even
to test a pure function. Both platforms are covered by the normal CI matrix
plus the `test-web` job.

Part of the Board Games Empire client monorepo; not published to pub.dev.
