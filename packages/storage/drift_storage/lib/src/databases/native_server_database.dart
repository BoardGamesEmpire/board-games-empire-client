import 'package:drift/native.dart';

import 'server_database.dart';

/// An in-memory [ServerDatabase] on the native (`dart:ffi`) executor.
///
/// Replaces the `ServerDatabase.memory()` constructor removed in #287.
/// [ServerDatabase] itself is executor-agnostic pure drift so that a web
/// build can import it; `NativeDatabase.memory()` is not, so the helper
/// lives here — behind `drift_storage_native.dart` — rather than on the
/// class.
///
/// Intended for VM tests and throwaway scratch databases: nothing is
/// persisted and the schema is created fresh by drift's `onCreate`. A
/// production database comes from `EncryptedExecutorFactory` (native) or
/// `web_storage`'s wasm executor (#288) instead.
ServerDatabase inMemoryServerDatabase() =>
    ServerDatabase(NativeDatabase.memory());
