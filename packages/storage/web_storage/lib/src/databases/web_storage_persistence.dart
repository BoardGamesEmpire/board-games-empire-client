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

  /// Data survives a reload, but a second tab can race it.
  ///
  /// `unsafeIndexedDb` — no worker is available to serialize access, so two
  /// tabs writing at once can interleave. Drift names it "unsafe" for that
  /// reason, and so does this.
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
