import 'package:app_shell/app_shell.dart';
import 'package:desktop_platform/desktop.dart';

Future<void> main() async {
  // Observability wiring — the root logger, the platform log sink
  // (DevTools console + rotating file on desktop), and build-mode level
  // filtering — is set up inside runBgeApp via
  // ShellObservability.initialize + DesktopPlatformBootstrap.createLogSink
  // (#100). The app entrypoint stays thin.
  await runBgeApp(platformBootstrap: DesktopPlatformBootstrap());
}
