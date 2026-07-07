import 'package:app_shell/app_shell.dart';
import 'package:web_platform/web.dart';

Future<void> main() async {
  // Path-based URLs so the reserved deep-link paths (#10) are real
  // browser URLs; must run before the router is built.
  configureWebUrlStrategy();
  await runBgeApp(platformBootstrap: const WebPlatformBootstrap());
}
