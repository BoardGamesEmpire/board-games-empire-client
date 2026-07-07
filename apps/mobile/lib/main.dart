import 'package:app_shell/app_shell.dart';
import 'package:mobile_platform/mobile.dart';

Future<void> main() async {
  await runBgeApp(platformBootstrap: MobilePlatformBootstrap());
}
