/// The platform-neutral half of `drift_storage` (#287, #63 D2).
///
/// Everything exported here is executor-agnostic pure drift and compiles for
/// web: the two databases take their `QueryExecutor` from the caller, and the
/// repositories only ever talk to a database handed to them. A web build
/// pairs these with `web_storage`'s wasm executor (#288); a native build
/// pairs them with `drift_storage_native.dart`, which carries the `dart:io`
/// and `dart:ffi` surface (the encrypted executor factory, the per-server
/// storage installer, the in-memory test helper).
///
/// Nothing exported from here may name `dart:io`, `dart:ffi` or
/// `package:drift/native.dart`, transitively included —
/// `test/platform_boundary_test.dart` enforces it.
library;

export 'src/composition/user_session_scope_installer.dart';

export 'src/databases/meta_database.dart';
export 'src/databases/server_database.dart';

export 'src/repositories/device_preferences_repository_impl.dart';
export 'src/repositories/game_collection_repository_impl.dart';
export 'src/repositories/game_repository_impl.dart';
export 'src/repositories/household_repository_impl.dart';
export 'src/repositories/notification_summary_repository_impl.dart';
export 'src/repositories/server_repository_impl.dart';
export 'src/repositories/sync_queue_repository_impl.dart';
