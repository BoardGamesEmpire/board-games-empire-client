import 'dart:async';

import 'package:alchemist/alchemist.dart';

/// Alchemist bootstrap for this package's test suite.
///
/// Default config: on CI (detected via the `CI` env var) goldens render
/// text as Ahem blocks and compare against `test/**/goldens/ci/`; on a dev
/// machine, human-readable platform goldens are generated under
/// `goldens/<platform>/` (gitignored — only CI goldens are committed).
/// Golden tests carry the `golden` tag: `flutter test --exclude-tags
/// golden` skips them, `--update-goldens` regenerates.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(),
    run: testMain,
  );
}
