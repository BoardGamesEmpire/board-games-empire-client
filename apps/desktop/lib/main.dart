import 'package:app_shell/app_shell.dart';
import 'package:desktop_platform/desktop.dart';

Future<void> main() async {
  await runBgeApp(platformBootstrap: DesktopPlatformBootstrap());
}
