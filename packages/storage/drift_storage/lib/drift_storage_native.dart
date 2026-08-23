/// The native half of `drift_storage` (#287): everything that needs
/// `dart:io`, `dart:ffi` or SQLCipher.
///
/// `drift_storage.dart` is the platform-neutral entry point — the databases
/// as executor-agnostic classes, every repository implementation, and the
/// user-session installer — and a web target imports only that (#63 D2).
/// This library is the complement: the executor factory that opens an
/// encrypted file-backed database (#16), the per-server storage installer
/// that resolves paths on disk, and the in-memory helper VM tests use.
///
/// A native composition root imports **both**; nothing on web imports this
/// one. The split is a plain second entry point rather than conditional
/// exports so the platform boundary is visible at the import site: a file
/// naming this library cannot compile for web, and it is obvious why.
///
/// Enforced by `test/platform_boundary_test.dart`, which walks the source
/// closure of each entry point.
library;

export 'src/composition/storage_scope_installer.dart';

export 'src/databases/encrypted_executor_factory.dart';
export 'src/databases/native_server_database.dart';
