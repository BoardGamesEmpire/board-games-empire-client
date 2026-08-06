import 'dart:async';

import 'package:alchemist/alchemist.dart';

/// Alchemist bootstrap for this package's test suite.
///
/// Only the CI variant runs: goldens render text as Ahem blocks and
/// compare against `test/**/goldens/ci/`, which is the one baseline set
/// committed to the repo. Golden tests carry the `golden` tag, so
/// `flutter test --exclude-tags golden` skips them (what `melos run test`
/// and CI both do), `--tags golden` runs only them (`melos run
/// test:goldens`), and `--update-goldens` regenerates them
/// (`melos run goldens:update`).
///
/// The per-host platform variant is disabled deliberately. Alchemist's
/// docs and its own class comments describe platform goldens as
/// "generated but never compared", and older versions skipped them off
/// CI via a `CI` env var — neither is true in 0.14.0. There is no env-var
/// detection left in the package, `PlatformGoldensConfig.enabled`
/// defaults to true, and `alchemist_test_variant.dart` performs a real
/// comparison for every enabled variant. Since `goldens/<platform>/` is
/// gitignored, leaving it on meant `flutter test` failed on a fresh clone
/// with "Could not be compared against non-existent file" — a missing
/// baseline is a hard failure, not a skip.
///
/// Re-enable only alongside a decision about which host renders the
/// baseline; see #159.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(
      platformGoldensConfig: PlatformGoldensConfig(enabled: false),
    ),
    run: testMain,
  );
}
