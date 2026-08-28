/// The browser-only half of the web composition root (#288 **D3**).
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
library;

export 'src/web_storage_composition.dart';
