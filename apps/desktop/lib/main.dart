import 'dart:developer' as developer;

import 'package:app_shell/app_shell.dart';
import 'package:desktop_platform/desktop.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

Future<void> main() async {
  // TEMP (#101, removed by #100): in debug builds attach a stdout sink to
  // Logger.root so BgeLogger output is visible while diagnosing runtime
  // failures. Gated to debug-only so a release binary neither raises the root
  // level to ALL nor risks diagnostic context reaching production logs (PR
  // #103 review). #100 replaces this with proper per-platform sink + level
  // wiring.
  if (kDebugMode) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      final ctx = record.object; // ContextLogMessage when context was supplied
      // ignore: avoid_print
      developer.log(
        record.message,
        time: record.time,
        level: record.level.value,
        name: record.loggerName,
        error: record.error,
        stackTrace: record.stackTrace,
      );
      if (ctx != null && ctx.toString() != record.message) {
        // ignore: avoid_print
        developer.log(ctx.toString(), name: record.loggerName);
      }
    });
  }

  await runBgeApp(platformBootstrap: DesktopPlatformBootstrap());
}
