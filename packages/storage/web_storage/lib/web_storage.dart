/// The web half of the BGE data layer (#288, #63): a drift/wasm
/// `QueryExecutor` and the install path that registers a `ServerDatabase`
/// over it.
///
/// Everything else — both databases, all seven repositories, the user-session
/// installer — is shared, platform-neutral code in `drift_storage.dart`
/// (#287). This package adds an executor and nothing more; there is no
/// web-specific query anywhere in the tree.
///
/// **Web is imported by web targets only.** Every library here reaches
/// `package:drift/wasm.dart`, which reaches `dart:js_interop` — so a VM or
/// native build cannot compile this package, by construction rather than by
/// convention. The complement of `drift_storage_native.dart`, and enforced
/// the same way: `test/platform_boundary_test.dart` walks this package's
/// source closure and fails on a library that is not web-safe.
///
/// No at-rest encryption, deliberately (#63) — see
/// [WebWasmExecutorFactory], which carries the full reasoning at the point
/// the executor is built.
library;

export 'src/composition/web_storage_installer.dart';

export 'src/databases/wasm_executor_factory.dart';
export 'src/databases/web_storage_persistence.dart';
