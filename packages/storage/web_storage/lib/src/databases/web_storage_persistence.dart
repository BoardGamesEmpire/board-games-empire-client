import 'package:drift/wasm.dart' show WasmStorageImplementation;

/// How much persistence the browser actually gave us.
///
/// Drift picks a storage implementation from whatever the browser supports,
/// and the choice ranges from "as good as a file on disk" to "nothing is
/// stored at all". That difference matters to the app — an offline-capable
/// shell over [ephemeral] storage is a promise it cannot keep — but
/// [WasmStorageImplementation] states it as six mechanisms rather than as a
/// guarantee. This is the guarantee.
///
/// Deliberately platform-free so it is testable without a browser: the
/// mapping is the interesting part, and it is a pure function.
enum WebStoragePersistence {
  /// Data survives a reload and is safe against a second tab.
  ///
  /// Both OPFS modes and the shared-worker IndexedDB mode: writes are
  /// serialized through one owner, so concurrent tabs cannot corrupt the
  /// database.
  ///
  /// **Not a promise about eviction.** All three of these live in the
  /// origin's storage bucket, which a browser may clear under storage
  /// pressure unless the origin holds a `navigator.storage.persist()` grant
  /// — OPFS on exactly the same terms as IndexedDB, so this is not a reason
  /// to rank one below the other. Nothing here requests that grant, which
  /// means [durable] says the data is *stored*, not that the browser has
  /// promised to keep it. Requesting it is a real improvement and a real
  /// behaviour change (Firefox prompts the user), so it is a decision to
  /// take deliberately rather than a detail to slip in here.
  durable,

  /// Data survives a reload, but only one tab at a time can have it open.
  ///
  /// `unsafeIndexedDb` — no shared worker is available to serialize access,
  /// so each tab runs its own copy of the database, read from IndexedDB once
  /// when it opened, and writes its changes back over the other tabs'. No
  /// tab sees another's writes, and no lock around the queries can change
  /// that. Drift names it "unsafe" for that reason, and so does this.
  ///
  /// So the tab that opens it holds it until it closes it, and a second tab
  /// opens nothing: `WebStorageInstaller` throws `WebDatabaseInUse` before
  /// that tab's first query, so it reads and writes nothing, and the app
  /// shows it as open in another tab (#686). A browser context without Web
  /// Locks can't hold it, and there a second tab can still overwrite the
  /// first one's writes.
  unsafe,

  /// Nothing is stored. A reload starts from empty.
  ///
  /// The in-memory fallback, chosen when the browser supports none of the
  /// persistence mechanisms.
  ephemeral;

  /// Classifies [implementation].
  ///
  /// Written as an exhaustive switch on purpose: a new implementation added
  /// upstream fails to compile here rather than being silently classified,
  /// which is the failure mode a `default` branch would produce.
  static WebStoragePersistence of(WasmStorageImplementation implementation) {
    return switch (implementation) {
      WasmStorageImplementation.opfsShared ||
      WasmStorageImplementation.opfsLocks ||
      WasmStorageImplementation.sharedIndexedDb => durable,
      WasmStorageImplementation.unsafeIndexedDb => unsafe,
      WasmStorageImplementation.inMemory => ephemeral,
    };
  }

  /// Whether data written here survives a page reload.
  bool get isPersistent => this != ephemeral;
}
