import 'package:app_shell/app_shell.dart';
import 'package:web_platform/web.dart';
// The browser-only half of the composition root (#288): the drift/wasm data
// layer. Split from `web.dart` so that barrel stays VM-compilable — see the
// library docs there. `const WebPlatformBootstrap()` would still boot, just
// without a database, which is why the composed bootstrap has its own name.
import 'package:web_platform/web_storage_composition.dart';

Future<void> main() async {
  // Path-based URLs so the reserved deep-link paths (#10) are real
  // browser URLs; must run before the router is built.
  configureWebUrlStrategy();
  await runBgeApp(platformBootstrap: bgeWebPlatformBootstrap());
}
