/// The browser-only half of the web composition root (#288).
///
/// The complement of `web.dart`, and split from it for the same reason
/// `drift_storage_native.dart` is split from `drift_storage.dart` (#287): the
/// libraries reachable from here are not compilable off the web.
/// `web_storage` reaches `dart:js_interop` through `package:drift/wasm.dart`,
/// so a single export of this library from `web.dart` would make every
/// consumer browser-only — including this package's own test suite, which is
/// widget tests on the VM.
///
/// **Only the browser app imports this.** It imports `web.dart` too; nothing
/// else imports this one. A file naming this library cannot run on the VM,
/// and it is obvious from the import site why.
///
/// Since #292 it also carries the durable `FeedbackSink`, which is browser-only
/// for its own reason — `dart:js_interop` directly, rather than through drift.
/// It belongs behind the same barrel because it is the same thing: web storage,
/// composed into the app by the one caller that can compile it.
///
/// Since #432 it also carries the session monitor's browser bindings — a
/// `BroadcastChannel` and the page's focus and visibility events — for the
/// same reason: `dart:js_interop`, composed by the one caller that compiles
/// it.
///
/// Since #447 it also carries the sync drain's cross-tab lock, over the
/// browser's Web Locks, again for `dart:js_interop`: it keeps the tabs that
/// share one database from draining it at once.
library;

export 'src/feedback/indexed_db_feedback_sink.dart';
export 'src/session/web_session_bindings.dart';
export 'src/sync/web_cross_tab_lock.dart';
export 'src/web_storage_composition.dart';
