/// Web composition root for Board Games Empire.
///
/// Platform-neutral in the same sense as `drift_storage.dart` (#287): every
/// library reachable from here compiles for the VM, so this package's own
/// tests — widget tests included — run in the normal test matrix.
///
/// The data layer is deliberately NOT here. `web_storage` reaches
/// `dart:js_interop`, and exporting it from this barrel would make every
/// consumer, this package's test suite included, browser-only. It lives
/// behind `web_storage_composition.dart`, which the browser app imports and
/// nothing else does (#288).
library;

export 'src/build_info/package_info_build_info_reader.dart';
export 'src/web_platform_bootstrap.dart';
export 'src/web_root_module.dart';
