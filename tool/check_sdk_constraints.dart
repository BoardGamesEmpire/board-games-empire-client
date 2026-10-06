// Verifies the invariants that hold across every package in the
// workspace. Three of them today:
//
//   1. SDK constraints match the root pubspec (#153) — the bulk of this
//      file. `--fix` repairs it.
//   2. Every pubspec, root included, declares `publish_to: none` (#156).
//   3. Every app reports the root pubspec's `version:` (#73). `--fix`
//      repairs the pubspecs; the native manifests are check-only.
//
// Kept under this filename because CI, the `check:constraints` melos
// script, and a handful of comments all reference it; the name is
// narrower than the remit.
//
// ── 1. SDK constraints ─────────────────────────────────────────────
//
// The root `environment.flutter` is an exact version and is the single
// source of truth for the toolchain — CI installs exactly it via
// `flutter-version-file: pubspec.yaml`. This script propagates that
// decision outward:
//
//   * every package's `environment.sdk` must match the root's verbatim;
//   * a package that pulls anything from the Flutter SDK must declare
//     `flutter: ">=<root pin>"`, and one that does not must declare no
//     `flutter:` key at all.
//
// The point is that `flutter: ">=3.0.0"` — the `flutter create` default
// that prompted #153 — can never fail a resolve, because the Dart floor
// already excludes every Flutter old enough for it to matter. pub cannot
// catch that; this can.
//
// Deliberately holds no Flutter-to-Dart version table. It checks
// internal consistency with the root, not the external release history,
// so there is nothing here to keep current.
//
// ── 2. publish_to ──────────────────────────────────────────────────
//
// Nothing in this repo is published. `publish_to: none` is the explicit
// guard, and it was absent on exactly two packages (core/di,
// core/interfaces) plus the root while present on the other 26 — an
// oversight, not a decision (#156). Unlike the SDK invariant this one
// covers the root pubspec as well, since `dart pub publish` from the
// workspace root would target `board_games_empire`.
//
// Check-only: it is a one-line edit, and a rewriter would need its own
// raw-line inserter and self-test fixtures for no real gain.
//
// ── 3. The client version ──────────────────────────────────────────
//
// The root `version:` is the client's one version, build number
// included, and it must have one. Every workspace member directly under
// apps/ must declare the same string; libraries are not checked, since
// nothing reads their `version:`. Flutter carries the app's version
// into every platform build, so equal pubspecs mean every platform
// reports the same version, provided each native manifest still takes
// its version from Flutter. The script also checks that, for each
// platform an app builds: the Android Gradle file, the iOS and macOS
// Info.plist files, and the Windows runner's CMakeLists.txt and
// Runner.rc (`_manifests`).
//
// `--fix` rewrites an app's `version:` line, as it does the SDK
// constraints. The manifests are check-only, like publish_to: the fix is
// restoring Flutter's own template lines.
//
// ── Coverage ───────────────────────────────────────────────────────
//
// Packages are discovered from the root `workspace:` list, not from
// disk, so a package that exists but is not listed is invisible to every
// invariant. That is the right trade — an unlisted package is not part
// of the resolve — but do not read this as "every package on disk".
//
// Usage:
//   dart run tool/check_sdk_constraints.dart          # report, exit 1 on drift
//   dart run tool/check_sdk_constraints.dart --fix    # rewrite pubspec drift
//   dart run tool/check_sdk_constraints.dart --self-test
//
// Bumping the toolchain is therefore: edit the root `environment:`
// block, then run with `--fix`. Bumping the client version is the same,
// with the root `version:`.

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

void main(List<String> args) {
  final fix = args.contains('--fix');
  final unknown = args.where((a) => a != '--fix' && a != '--self-test');
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln(
      'Usage: dart run tool/check_sdk_constraints.dart [--fix|--self-test]',
    );
    exit(64); // EX_USAGE
  }

  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }

  final root = File('pubspec.yaml');
  if (!root.existsSync()) {
    stderr.writeln('pubspec.yaml not found. Run this from the workspace root.');
    exit(1);
  }

  final rootYaml = loadYaml(root.readAsStringSync()) as YamlMap;
  final rootEnv = rootYaml['environment'] as YamlMap?;
  if (rootEnv == null) {
    stderr.writeln('Root pubspec.yaml has no `environment:` block.');
    exit(1);
  }

  final expectedSdk = rootEnv['sdk']?.toString();
  final pin = rootEnv['flutter']?.toString();

  if (expectedSdk == null) {
    stderr.writeln('Root pubspec.yaml declares no `environment.sdk`.');
    exit(1);
  }
  if (pin == null) {
    stderr.writeln('Root pubspec.yaml declares no `environment.flutter`.');
    exit(1);
  }

  // CI resolves the toolchain by reading this value literally, so it has
  // to stay a bare version. A range here would silently break the
  // `flutter-version-file` lookup in .github/workflows/ci.yaml.
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(pin)) {
    stderr.writeln(
      'Root `environment.flutter` must be an exact version (e.g. 3.44.4), '
      'not a range — CI reads it via `flutter-version-file`. Found: $pin',
    );
    exit(1);
  }

  final expectedFlutter = '>=$pin';

  final expectedVersion = rootYaml['version']?.toString();
  if (expectedVersion == null) {
    stderr.writeln('Root pubspec.yaml declares no `version:`.');
    exit(1);
  }

  // The one shape every platform reports unchanged. The comment on the
  // root `version:` gives the reasons; the prerelease one is in
  // flutter_tools' `validatedBuildNameForPlatform`, which strips iOS and
  // macOS versions to digits and dots. The shape also keeps `--fix` safe:
  // a value like this is a string in YAML, so it can be written unquoted.
  if (!RegExp(r'^\d+\.\d+\.\d+\+\d+$').hasMatch(expectedVersion)) {
    stderr.writeln(
      'Root `version:` must be major.minor.patch+build, all numeric '
      '(e.g. 1.2.3+4). Found: $expectedVersion',
    );
    exit(1);
  }
  // Length first, so a long run of digits never reaches int.parse.
  final parts = expectedVersion.split(RegExp(r'[.+]'));
  if (parts.any((p) => p.length > 5 || int.parse(p) > 65535) ||
      int.parse(parts.last) < 1) {
    stderr.writeln(
      'Root `version:` parts must each be at most 65535, the size of a '
      "Windows version field, and the build number at least 1, Android's "
      'lowest versionCode. Found: $expectedVersion',
    );
    exit(1);
  }

  final members = (rootYaml['workspace'] as YamlList?)?.cast<String>();
  if (members == null || members.isEmpty) {
    stderr.writeln('Root pubspec.yaml lists no `workspace:` members.');
    exit(1);
  }

  // An app is a member directly under apps/. A library nested deeper,
  // such as a plugin kept beside its app, has no client version to hold.
  // Loud rather than a pass when there is none: the version invariant
  // would check nothing and still report success.
  final apps = members.where(RegExp(r'^apps/[^/]+$').hasMatch).toSet();
  if (apps.isEmpty) {
    stderr.writeln(
      'No `workspace:` member is under apps/, so there is no app version '
      'to check.',
    );
    exit(1);
  }

  final sdkProblems = <String>[];
  final versionProblems = <String>[];
  final publishProblems = <String>[];
  final unfixable = <String>[];
  // A set, since one pubspec can need both rewrites.
  final rewrittenPaths = <String>{};
  // The problems a rewrite cleared, which are all --fix may claim. One
  // pubspec can have a version it rewrote beside an environment it
  // could not.
  final fixed = <String>[];

  // The root is a real package too — `dart pub publish` from here would
  // target `board_games_empire` — so it gets the publish_to check even
  // though it is not one of its own `workspace:` members.
  _checkPublishTo('pubspec.yaml', rootYaml, publishProblems);

  for (final dir in members) {
    final path = '$dir/pubspec.yaml';
    final file = File(path);
    if (!file.existsSync()) {
      final problem = '$path: listed in `workspace:` but does not exist';
      sdkProblems.add(problem);
      if (fix) unfixable.add(problem);
      continue;
    }

    var source = file.readAsStringSync();
    final yaml = loadYaml(source) as YamlMap;

    // Before the environment checks, which `continue` past this point.
    _checkPublishTo(path, yaml, publishProblems);

    // Only the apps: nothing reads a library's `version:`.
    if (apps.contains(dir)) {
      final actualVersion = yaml['version']?.toString();
      if (actualVersion != expectedVersion) {
        final problem =
            '$path: version is ${_show(actualVersion)}, expected '
            '${_show(expectedVersion)}';
        versionProblems.add(problem);
        if (fix) {
          final rewritten = _rewriteVersion(source, expectedVersion);
          if (rewritten == null) {
            unfixable.add(
              '$path: could not locate a top-level `version:` line to '
              'rewrite — fix this one by hand',
            );
          } else {
            file.writeAsStringSync(rewritten);
            // The environment rewrite below starts from this text, so it
            // keeps the new version line.
            source = rewritten;
            rewrittenPaths.add(path);
            fixed.add(problem);
          }
        }
      }
    }

    // No block, or an empty one, reads as absent keys. The rewriter fills
    // an empty block and reports a missing one as unfixable.
    final env = yaml['environment'] as YamlMap?;
    final wantFlutter = _usesFlutterSdk(yaml) ? expectedFlutter : null;
    final actualSdk = env?['sdk']?.toString();
    final actualFlutter = env?['flutter']?.toString();

    if (actualSdk == expectedSdk && actualFlutter == wantFlutter) continue;

    final drift = <String>[];
    if (actualSdk != expectedSdk) {
      drift.add(
        '$path: sdk is ${_show(actualSdk)}, expected ${_show(expectedSdk)}',
      );
    }
    if (actualFlutter != wantFlutter) {
      drift.add(
        wantFlutter == null
            ? '$path: declares flutter ${_show(actualFlutter)} but depends on '
                  'nothing from the Flutter SDK — the key should be removed'
            : actualFlutter == null
            ? '$path: depends on the Flutter SDK but declares no '
                  '`flutter:` constraint, expected ${_show(wantFlutter)}'
            : '$path: flutter is ${_show(actualFlutter)}, expected '
                  '${_show(wantFlutter)}',
      );
    }
    sdkProblems.addAll(drift);

    if (fix) {
      final rewritten = _rewriteEnvironment(source, expectedSdk, wantFlutter);
      if (rewritten == null) {
        // Never report a fix that did not happen. A silent no-op here
        // would read as "fixed" and leave the next run still failing.
        unfixable.add(
          '$path: could not locate a top-level `environment:` block to '
          'rewrite — fix this one by hand',
        );
      } else {
        file.writeAsStringSync(rewritten);
        rewrittenPaths.add(path);
        fixed.addAll(drift);
      }
    }
  }

  final manifestProblems = <String>[];
  var manifestCount = 0;
  for (final app in apps) {
    for (final (relative, check) in _manifests) {
      // Only the platforms this app builds.
      final platform = relative.substring(0, relative.indexOf('/'));
      if (!Directory('$app/$platform').existsSync()) continue;
      manifestCount++;
      final path = '$app/$relative';
      final file = File(path);
      if (!file.existsSync()) {
        // Loud rather than skipped: a manifest that moved would otherwise
        // drop out of the check without anyone noticing.
        manifestProblems.add(
          '$path: does not exist, though $app builds for $platform — if '
          'it moved, update `_manifests`',
        );
        continue;
      }
      for (final p in check(file.readAsStringSync())) {
        manifestProblems.add('$path: $p');
      }
    }
  }

  // The check-only invariants are reported before the rewritable ones
  // and never repaired by --fix, so they get their own exit path.
  // Folding them into the rewritable lists would make --fix claim to
  // have rewritten something it cannot touch.
  if (publishProblems.isNotEmpty) {
    // "does not declare", not "missing": the check also catches a
    // publish_to that is present but set to something else, where
    // "missing" would misdescribe it.
    stderr.writeln(
      '${publishProblems.length} pubspec(s) do not declare '
      '`publish_to: none`:',
    );
    for (final p in publishProblems) {
      stderr.writeln('  $p');
    }
    stderr.writeln(
      '\nNothing in this repo is published. Set `publish_to: none` below '
      '`description:` in each — this check does not rewrite it for you.',
    );
  }

  if (manifestProblems.isNotEmpty) {
    stderr.writeln(
      '${manifestProblems.length} native manifest problem(s), where a '
      'version is not taken from Flutter:',
    );
    for (final p in manifestProblems) {
      stderr.writeln('  $p');
    }
    stderr.writeln(
      "\nFlutter fills these in from the app's pubspec `version:`, which "
      "the root pubspec sets. Restore Flutter's template values and remove "
      'any override — this check does not rewrite them for you.',
    );
  }

  final checkOnlyFailed =
      publishProblems.isNotEmpty || manifestProblems.isNotEmpty;
  final problems = [...sdkProblems, ...versionProblems];

  if (problems.isEmpty) {
    if (checkOnlyFailed) exit(1);
    stdout.writeln(
      'Workspace invariants hold across ${members.length} packages plus '
      'the root (Flutter $pin, sdk $expectedSdk, publish_to none, version '
      '$expectedVersion in ${apps.length} apps and $manifestCount native '
      'manifests).',
    );
    return;
  }

  if (fix) {
    if (fixed.isNotEmpty) {
      stdout.writeln('Rewrote ${rewrittenPaths.length} pubspec(s):');
      for (final p in fixed) {
        stdout.writeln('  $p');
      }
    }
    if (unfixable.isNotEmpty) {
      stderr.writeln('\nCould not rewrite ${unfixable.length} pubspec(s):');
      for (final p in unfixable) {
        stderr.writeln('  $p');
      }
      exit(1);
    }
    if (checkOnlyFailed) exit(1);
    stdout.writeln('Run `flutter pub get` to re-resolve.');
    return;
  }

  if (sdkProblems.isNotEmpty) {
    stderr.writeln(
      'SDK constraint drift against the root pin (Flutter $pin, '
      'sdk $expectedSdk):',
    );
    for (final p in sdkProblems) {
      stderr.writeln('  $p');
    }
  }
  if (versionProblems.isNotEmpty) {
    if (sdkProblems.isNotEmpty) stderr.writeln();
    stderr.writeln(
      'App version drift against the root `version:` ($expectedVersion):',
    );
    for (final p in versionProblems) {
      stderr.writeln('  $p');
    }
  }
  stderr.writeln('\nFix with: dart run tool/check_sdk_constraints.dart --fix');
  exit(1);
}

/// Records a problem unless [pubspec] declares `publish_to: none`.
///
/// Reads the parsed value rather than matching raw text: quoting varies
/// across the workspace (`none` in most, `'none'` in three), and YAML
/// resolves both to the same string, where a regex would have to know
/// about both.
void _checkPublishTo(String path, YamlMap pubspec, List<String> problems) {
  final actual = pubspec['publish_to']?.toString();
  if (actual == 'none') return;
  problems.add('$path: publish_to is ${_show(actual)}, expected "none"');
}

String _show(String? value) => value == null ? '(absent)' : '"$value"';

/// Fixture tests for the rewriters ([_rewriteEnvironment],
/// [_rewriteVersion]) and the manifest checks.
///
/// A rewriter's failure mode is a silent no-op — it returns something
/// plausible, `--fix` reports success, and the drift is still there on the
/// next run. That is invisible to the workspace check itself, because the
/// workspace only ever holds already-correct pubspecs. So the shapes it
/// has to survive are pinned here instead. The manifest checks have the
/// same blind spot from the other side: the real manifests are correct,
/// so only a fixture shows that a hand-set value fails. Run by the
/// `constraints` CI job.
void _selfTest() {
  const sdk = '^3.12.0';
  const flutter = '>=3.44.4';
  var failures = 0;

  // Compared as JSON so the manifest checks' problem lists can be pinned
  // the same way as the rewriters' strings.
  void expect(String name, Object? actual, Object? expected) {
    if (jsonEncode(actual) == jsonEncode(expected)) {
      stdout.writeln('  ok   $name');
    } else {
      failures++;
      stdout.writeln('  FAIL $name');
      stdout.writeln('       expected: ${jsonEncode(expected)}');
      stdout.writeln('       actual:   ${jsonEncode(actual)}');
    }
  }

  expect(
    'rewrites both keys',
    _rewriteEnvironment(
      'name: a\nenvironment:\n  sdk: ">=3.9.0 <4.0.0"\n'
      '  flutter: ">=3.0.0"\nresolution: workspace\n',
      sdk,
      flutter,
    ),
    'name: a\nenvironment:\n  sdk: ^3.12.0\n'
        '  flutter: ">=3.44.4"\nresolution: workspace\n',
  );

  expect(
    'inserts a missing flutter floor',
    _rewriteEnvironment(
      'environment:\n  sdk: ">=3.9.0 <4.0.0"\nresolution: workspace\n',
      sdk,
      flutter,
    ),
    'environment:\n  sdk: ^3.12.0\n  flutter: ">=3.44.4"\n'
        'resolution: workspace\n',
  );

  // Regression: --fix used to report success and change nothing here.
  expect(
    'inserts a missing sdk floor',
    _rewriteEnvironment(
      'environment:\n  flutter: ">=3.0.0"\nresolution: workspace\n',
      sdk,
      flutter,
    ),
    'environment:\n  sdk: ^3.12.0\n  flutter: ">=3.44.4"\n'
        'resolution: workspace\n',
  );

  expect(
    'writes an empty environment block',
    _rewriteEnvironment('environment:\nresolution: workspace\n', sdk, null),
    'environment:\n  sdk: ^3.12.0\nresolution: workspace\n',
  );

  // Regression: the block used to be found by exact string equality.
  expect(
    'matches environment: with a trailing comment',
    _rewriteEnvironment(
      'environment: # toolchain\n  sdk: ">=3.9.0 <4.0.0"\n'
      '  flutter: ">=3.0.0"\nresolution: workspace\n',
      sdk,
      flutter,
    ),
    'environment: # toolchain\n  sdk: ^3.12.0\n'
        '  flutter: ">=3.44.4"\nresolution: workspace\n',
  );

  expect(
    'drops the flutter key for a Flutter-free package',
    _rewriteEnvironment(
      'environment:\n  sdk: ">=3.9.0 <4.0.0"\n  flutter: ">=3.0.0"\n'
      'resolution: workspace\n',
      sdk,
      null,
    ),
    'environment:\n  sdk: ^3.12.0\nresolution: workspace\n',
  );

  expect(
    'preserves comments inside the block',
    _rewriteEnvironment(
      'environment:\n  # pinned, see root\n  sdk: ">=3.9.0 <4.0.0"\n'
      'resolution: workspace\n',
      sdk,
      null,
    ),
    'environment:\n  # pinned, see root\n  sdk: ^3.12.0\n'
        'resolution: workspace\n',
  );

  expect(
    'ignores an indented environment: key',
    _rewriteEnvironment('foo:\n  environment:\n    sdk: "x"\n', sdk, null),
    null,
  );

  expect(
    'reports failure when there is no environment block',
    _rewriteEnvironment('name: a\nresolution: workspace\n', sdk, null),
    null,
  );

  const version = '1.0.0+1';

  expect(
    'version: rewrites a drifted value',
    _rewriteVersion(
      'name: a\npublish_to: none\n\nversion: 0.9.0+3\n\nenvironment:\n',
      version,
    ),
    'name: a\npublish_to: none\n\nversion: 1.0.0+1\n\nenvironment:\n',
  );

  expect(
    'version: keeps a trailing comment',
    _rewriteVersion('version: 0.9.0+3 # bump at the root\n', version),
    'version: 1.0.0+1 # bump at the root\n',
  );

  expect(
    'version: replaces a quoted value',
    _rewriteVersion("version: '0.9.0+3' # quoted\n", version),
    'version: 1.0.0+1 # quoted\n',
  );

  expect(
    'version: adds the build number to a value without one',
    _rewriteVersion('version: 1.0.0\n', version),
    'version: 1.0.0+1\n',
  );

  // A hosted dependency's constraint is also spelled `version:`.
  expect(
    'version: ignores an indented version: key',
    _rewriteVersion(
      'dependencies:\n  foo:\n    hosted: https://example.com\n'
      '    version: ^0.9.0\nversion: 0.9.0+3\n',
      version,
    ),
    'dependencies:\n  foo:\n    hosted: https://example.com\n'
        '    version: ^0.9.0\nversion: 1.0.0+1\n',
  );

  expect(
    'version: inserts a missing line ahead of environment:',
    _rewriteVersion(
      'name: a\npublish_to: none\n\nenvironment:\n  sdk: ^3.12.0\n',
      version,
    ),
    'name: a\npublish_to: none\n\nversion: 1.0.0+1\n\n'
        'environment:\n  sdk: ^3.12.0\n',
  );

  expect(
    'version: inserts a line past an indented version: key',
    _rewriteVersion(
      'dependencies:\n  foo:\n    version: ^0.9.0\nenvironment:\n',
      version,
    ),
    'dependencies:\n  foo:\n    version: ^0.9.0\nversion: 1.0.0+1\n\n'
        'environment:\n',
  );

  // Rewriting only the key line would leave the value's continuation
  // behind, indented under the new one.
  expect(
    'version: reports failure for a value not on the key line',
    _rewriteVersion('version:\n  0.9.0+3\nenvironment:\n', version),
    null,
  );

  expect(
    'version: reports failure when there is nowhere to insert',
    _rewriteVersion('name: a\nresolution: workspace\n', version),
    null,
  );

  expect(
    'version: keeps CRLF line endings',
    _rewriteVersion('version: 0.9.0+3\r\nenvironment:\r\n', version),
    'version: 1.0.0+1\r\nenvironment:\r\n',
  );

  expect(
    'version: inserts with CRLF line endings',
    _rewriteVersion('name: a\r\nenvironment:\r\n', version),
    'name: a\r\nversion: 1.0.0+1\r\n\r\nenvironment:\r\n',
  );

  expect(
    'environment: keeps CRLF line endings',
    _rewriteEnvironment(
      'environment:\r\n  sdk: ">=3.9.0 <4.0.0"\r\nresolution: workspace\r\n',
      sdk,
      null,
    ),
    'environment:\r\n  sdk: ^3.12.0\r\nresolution: workspace\r\n',
  );

  const gradleTemplate =
      'defaultConfig {\n'
      '    versionCode = flutter.versionCode\n'
      '    versionName = flutter.versionName\n'
      '}\n';

  expect(
    'gradle: flags a hand-set versionCode',
    _gradleVersionProblems(
      'defaultConfig {\n    versionCode = 3\n'
      '    versionName = flutter.versionName\n}\n',
    ),
    [
      '`versionCode = 3` overrides the version Flutter sets',
      'lacks `versionCode = flutter.versionCode`',
    ],
  );

  expect(
    'gradle: flags a missing versionName',
    _gradleVersionProblems(
      'defaultConfig {\n    versionCode = flutter.versionCode\n}\n',
    ),
    ['lacks `versionName = flutter.versionName`'],
  );

  expect(
    "gradle: accepts Flutter's values around comments and reads",
    _gradleVersionProblems(
      'defaultConfig {\n'
      '    // versionCode = 3\n'
      '    /*\n    versionName = "0.9"\n    */\n'
      '    versionCode = flutter.versionCode // from the pubspec\n'
      '    versionName = flutter.versionName\n'
      '    resValue("string", "app_version", flutter.versionName)\n'
      '}\n',
    ),
    <String>[],
  );

  expect(
    'gradle: flags a flavor that overrides the version',
    _gradleVersionProblems(
      '${gradleTemplate}productFlavors {\n    create("beta") {\n'
      '        versionName = "2.0-beta"\n    }\n}\n',
    ),
    ['`versionName = "2.0-beta"` overrides the version Flutter sets'],
  );

  // A suffix changes the versionName Android reports, so it is drift
  // like any other override.
  expect(
    'gradle: flags a versionNameSuffix',
    _gradleVersionProblems(
      '${gradleTemplate}buildTypes {\n    debug {\n'
      '        versionNameSuffix = "-dev"\n    }\n}\n',
    ),
    ['`versionNameSuffix = "-dev"` overrides the version Flutter sets'],
  );

  expect(
    'gradle: flags the other ways to set a version',
    _gradleVersionProblems(
      '${gradleTemplate}android.defaultConfig.versionCode = 3\n'
      'android { defaultConfig { versionCode += 1 } }\n'
      'setVersionName("2.0")\n'
      'output.versionCodeOverride = 5\n'
      'output.versionCode.set(5)\n',
    ),
    [
      '`android.defaultConfig.versionCode = 3` overrides the version '
          'Flutter sets',
      '`android { defaultConfig { versionCode += 1 } }` overrides the '
          'version Flutter sets',
      '`setVersionName("2.0")` overrides the version Flutter sets',
      '`output.versionCodeOverride = 5` overrides the version Flutter sets',
      '`output.versionCode.set(5)` overrides the version Flutter sets',
    ],
  );

  const cmakeTemplate =
      '# Add preprocessor definitions for the build version.\n'
      'target_compile_definitions(\${BINARY_NAME} PRIVATE '
      r'"FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")'
      '\n'
      'target_compile_definitions(\${BINARY_NAME} PRIVATE '
      r'"FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")'
      '\n'
      'target_compile_definitions(\${BINARY_NAME} PRIVATE '
      r'"FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")'
      '\n'
      'target_compile_definitions(\${BINARY_NAME} PRIVATE '
      r'"FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")'
      '\n'
      'target_compile_definitions(\${BINARY_NAME} PRIVATE '
      r'"FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")'
      '\n'
      'target_compile_definitions(\${BINARY_NAME} PRIVATE "NOMINMAX")\n';

  expect(
    "cmake: accepts Flutter's version defines",
    _cmakeVersionProblems(cmakeTemplate),
    <String>[],
  );

  // Without the defines, Runner.rc falls back to a hard-coded 1.0.0.
  expect(
    'cmake: flags a missing define and a hand-set one',
    _cmakeVersionProblems(
      cmakeTemplate
          .replaceFirst(
            r'"FLUTTER_VERSION=\"${FLUTTER_VERSION}\""',
            r'"FLUTTER_VERSION=\"2.0.0\""',
          )
          .replaceFirst(
            'target_compile_definitions(\${BINARY_NAME} PRIVATE '
                r'"FLUTTER_VERSION_BUILD',
            '# target_compile_definitions(\${BINARY_NAME} PRIVATE '
                r'"FLUTTER_VERSION_BUILD',
          ),
    ),
    [
      r'`target_compile_definitions(${BINARY_NAME} PRIVATE '
          r'"FLUTTER_VERSION=\"2.0.0\"")` overrides the version Flutter sets',
      r'lacks `target_compile_definitions(${BINARY_NAME} PRIVATE '
          r'"FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")`',
      r'lacks `target_compile_definitions(${BINARY_NAME} PRIVATE '
          r'"FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")`',
    ],
  );

  const rcTemplate =
      '// Version\n'
      '#if defined(FLUTTER_VERSION_MAJOR) && defined(FLUTTER_VERSION_MINOR) '
      '&& defined(FLUTTER_VERSION_PATCH) && defined(FLUTTER_VERSION_BUILD)\n'
      '#define VERSION_AS_NUMBER FLUTTER_VERSION_MAJOR,FLUTTER_VERSION_MINOR,'
      'FLUTTER_VERSION_PATCH,FLUTTER_VERSION_BUILD\n'
      '#else\n#define VERSION_AS_NUMBER 1,0,0,0\n#endif\n'
      '#if defined(FLUTTER_VERSION)\n'
      '#define VERSION_AS_STRING FLUTTER_VERSION\n'
      '#else\n#define VERSION_AS_STRING "1.0.0"\n#endif\n'
      'VS_VERSION_INFO VERSIONINFO\n'
      ' FILEVERSION VERSION_AS_NUMBER\n'
      ' PRODUCTVERSION VERSION_AS_NUMBER\n'
      'BEGIN\n'
      r'            VALUE "FileVersion", VERSION_AS_STRING "\0"'
      '\n'
      r'            VALUE "ProductName", "desktop" "\0"'
      '\n'
      r'            VALUE "ProductVersion", VERSION_AS_STRING "\0"'
      '\n'
      'END\n';

  expect(
    "rc: accepts Flutter's version resource",
    _rcVersionProblems(rcTemplate),
    <String>[],
  );

  expect(
    'rc: flags a hand-set FILEVERSION and ProductVersion',
    _rcVersionProblems(
      rcTemplate
          .replaceFirst('FILEVERSION VERSION_AS_NUMBER', 'FILEVERSION 1,0,0,1')
          .replaceFirst(
            r'"ProductVersion", VERSION_AS_STRING',
            r'"ProductVersion", "1.0.0.1"',
          ),
    ),
    [
      '`FILEVERSION 1,0,0,1` overrides the version Flutter sets',
      r'`VALUE "ProductVersion", "1.0.0.1" "\0"` overrides the version '
          'Flutter sets',
      'lacks `FILEVERSION VERSION_AS_NUMBER`',
      r'lacks `VALUE "ProductVersion", VERSION_AS_STRING "\0"`',
    ],
  );

  // Every template line is still there, so only the extra definitions
  // can give this away.
  expect(
    'rc: flags a version macro redefined after the template',
    _rcVersionProblems(
      rcTemplate.replaceFirst(
        'VS_VERSION_INFO',
        '#undef VERSION_AS_NUMBER\n'
            '#define VERSION_AS_NUMBER 2,0,0,0\n'
            '#  define VERSION_AS_STRING "2.0.0"\n'
            'VS_VERSION_INFO',
      ),
    ),
    [
      '`#undef VERSION_AS_NUMBER` overrides the version Flutter sets',
      '`#define VERSION_AS_NUMBER 2,0,0,0` overrides the version Flutter sets',
      '`#  define VERSION_AS_STRING "2.0.0"` overrides the version Flutter '
          'sets',
    ],
  );

  // Both leave every macro line in place and pick the 1.0.0 fallback.
  expect(
    "rc: flags a guard that no longer reads Flutter's defines",
    _rcVersionProblems(
      rcTemplate
          .replaceFirst(
            '#if defined(FLUTTER_VERSION_MAJOR)',
            '#undef FLUTTER_VERSION_MAJOR\n#if defined(FLUTTER_VERSION_MAJOR)',
          )
          .replaceFirst('#if defined(FLUTTER_VERSION)\n', '#if 0\n'),
    ),
    [
      '`#undef FLUTTER_VERSION_MAJOR` overrides the version Flutter sets',
      'lacks `#if defined(FLUTTER_VERSION)`',
    ],
  );

  expect(
    'plist: flags a hand-set CFBundleShortVersionString',
    _plistVersionProblems(
      '<dict>\n\t<key>CFBundleShortVersionString</key>\n'
      '\t<string>1.2</string>\n'
      '\t<key>CFBundleVersion</key>\n'
      '\t<string>\$(FLUTTER_BUILD_NUMBER)</string>\n</dict>\n',
    ),
    [
      'CFBundleShortVersionString is "1.2", expected '
          r'"$(FLUTTER_BUILD_NAME)"',
    ],
  );

  expect(
    'plist: flags a missing CFBundleVersion',
    _plistVersionProblems(
      '<dict>\n\t<key>CFBundleShortVersionString</key>\n'
      '\t<string>\$(FLUTTER_BUILD_NAME)</string>\n</dict>\n',
    ),
    [r'sets no CFBundleVersion string, expected "$(FLUTTER_BUILD_NUMBER)"'],
  );

  expect(
    "plist: accepts Flutter's values and ignores commented-out entries",
    _plistVersionProblems(
      '<dict>\n\t<!-- was:\n\t<key>CFBundleVersion</key>\n'
      '\t<string>7</string> -->\n'
      '\t<key>CFBundleShortVersionString</key>\n'
      '\t<string>\$(FLUTTER_BUILD_NAME)</string>\n'
      '\t<key>CFBundleVersion</key>\n'
      '\t<string>\$(FLUTTER_BUILD_NUMBER)</string>\n</dict>\n',
    ),
    <String>[],
  );

  if (failures > 0) {
    stderr.writeln('\n$failures self-test failure(s).');
    exit(1);
  }
  stdout.writeln('check_sdk_constraints self-test passed.');
}

/// Whether any dependency is sourced from the Flutter SDK.
///
/// Matches on the `sdk: flutter` source rather than a hardcoded package
/// list, so `flutter_test`, `flutter_localizations`, `flutter_web_plugins`
/// and anything added later are all caught. A dev-only dependency counts:
/// it still makes the package unbuildable without the Flutter SDK.
bool _usesFlutterSdk(YamlMap pubspec) {
  for (final key in const ['dependencies', 'dev_dependencies']) {
    final deps = pubspec[key];
    if (deps is! YamlMap) continue;
    for (final dep in deps.values) {
      if (dep is YamlMap && dep['sdk'] == 'flutter') return true;
    }
  }
  return false;
}

/// Matches the top-level `environment:` key, tolerating trailing spaces
/// and a trailing comment.
///
/// Anchored at column 0 on purpose. Matching a left-trimmed prefix
/// instead would also hit an indented `environment:` nested under some
/// other key, and `environment_overrides:` — both of which would rewrite
/// the wrong block.
final _environmentKey = RegExp(r'^environment:[ \t]*(#.*)?$');
final _sdkLine = RegExp(r'^\s*sdk:');
final _flutterLine = RegExp(r'^\s*flutter:');

/// Rewrites the `environment:` block, returning null if there is no
/// top-level block to rewrite.
///
/// Null rather than the unchanged source: the caller has to be able to
/// tell "nothing needed changing" from "I could not do this", or `--fix`
/// reports a fix it never made.
///
/// Edits raw lines rather than round-tripping through the YAML writer,
/// which would drop every comment in the file.
String? _rewriteEnvironment(String source, String sdk, String? flutter) {
  final eol = _lineEnding(source);
  final lines = source.split(eol);
  final start = lines.indexWhere(_environmentKey.hasMatch);
  if (start == -1) return null;

  // The block runs to the next line that is neither blank nor indented.
  var end = start + 1;
  while (end < lines.length) {
    final line = lines[end];
    if (line.trim().isEmpty || line.startsWith(RegExp(r'\s'))) {
      end++;
    } else {
      break;
    }
  }

  final block = lines.sublist(start + 1, end);
  final indent =
      RegExp(r'^(\s+)')
          .firstMatch(
            block.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '  x'),
          )
          ?.group(1) ??
      '  ';

  // Strip the two keys we own, remembering where the first one sat so the
  // replacements land in the same place rather than at the top of the
  // block. Anything else — comments, a `dart:` key — is left untouched.
  final rebuilt = <String>[];
  var anchor = -1;
  for (final line in block) {
    if (_sdkLine.hasMatch(line) || _flutterLine.hasMatch(line)) {
      anchor = anchor == -1 ? rebuilt.length : anchor;
    } else {
      rebuilt.add(line);
    }
  }
  // No sdk/flutter key at all: insert ahead of the block's existing
  // content so the constraints stay the first thing you read.
  if (anchor == -1) anchor = 0;

  rebuilt.insertAll(anchor, [
    '${indent}sdk: $sdk',
    if (flutter != null) '${indent}flutter: "$flutter"',
  ]);

  return [
    ...lines.sublist(0, start + 1),
    ...rebuilt,
    ...lines.sublist(end),
  ].join(eol);
}

/// The line ending [source] uses. A Windows checkout with
/// `core.autocrlf` has CRLF, and the rewriters' patterns end at `$`,
/// which a `\r` left on every line would never reach.
String _lineEnding(String source) => source.contains('\r\n') ? '\r\n' : '\n';

/// Matches the top-level `version:` key, anchored at column 0 for the
/// reason [_environmentKey] is: a hosted dependency's constraint is also
/// spelled `version:`, one level down.
final _versionLine = RegExp(r'^version:');

/// A `version:` line this rewriter can replace: a value on the line
/// itself, quoted or not, and an optional trailing comment to keep.
final _versionValue = RegExp(r'^version:[ \t]+[^\s#]+([ \t]+#.*)?[ \t]*$');

/// Sets the top-level `version:` to [version], returning null if it
/// cannot.
///
/// A pubspec with no `version:` gets one inserted ahead of
/// `environment:`, where Flutter's app template puts it. Null, as with
/// [_rewriteEnvironment], when there is no `environment:` to insert
/// ahead of, or when the value is not on the key's own line: replacing
/// only that line would leave the old value behind on the next.
///
/// Writes [version] unquoted, which `main` makes safe by refusing a root
/// value YAML would read as anything but a string.
String? _rewriteVersion(String source, String version) {
  final eol = _lineEnding(source);
  final lines = source.split(eol);
  final at = lines.indexWhere(_versionLine.hasMatch);
  if (at == -1) {
    final env = lines.indexWhere(_environmentKey.hasMatch);
    if (env == -1) return null;
    lines.insertAll(env, ['version: $version', '']);
    return lines.join(eol);
  }
  final match = _versionValue.firstMatch(lines[at]);
  if (match == null) return null;
  lines[at] = 'version: $version${match.group(1) ?? ''}';
  return lines.join(eol);
}

/// The native files that hold a version of their own, relative to an
/// app, each with the check for its format (#73). Each must take the
/// version from Flutter, which takes it from the app's pubspec.
///
/// An app is checked for every platform directory it has, so a platform
/// added later is covered without editing this list, and a file that
/// moved fails the check rather than dropping out of it. Web and Linux
/// read version.json, which has no field to edit.
const _manifests = <(String, List<String> Function(String))>[
  ('android/app/build.gradle.kts', _gradleVersionProblems),
  ('ios/Runner/Info.plist', _plistVersionProblems),
  ('macos/Runner/Info.plist', _plistVersionProblems),
  ('windows/runner/CMakeLists.txt', _cmakeVersionProblems),
  ('windows/runner/Runner.rc', _rcVersionProblems),
];

/// Holds a manifest's [lines] to the version lines of its Flutter
/// template: each of [required] must appear, and any other line that
/// [setsVersion] picks out is an override, unless it is one of the
/// template's own [optional] lines. Lines compare without their
/// whitespace, so indentation and spacing do not matter; callers strip
/// comments first.
///
/// An allowlist, not a list of known overrides, because each format has
/// more ways to set a version than a check could name.
List<String> _templateVersionProblems(
  Iterable<String> lines,
  List<String> required,
  bool Function(String line) setsVersion, {
  List<String> optional = const [],
}) {
  String compact(String line) => line.replaceAll(RegExp(r'\s'), '');
  final wanted = {for (final line in required) compact(line)};
  final allowed = {for (final line in optional) compact(line)};
  final seen = <String>{};
  final problems = <String>[];
  for (final line in lines.map((l) => l.trim())) {
    final key = compact(line);
    if (wanted.contains(key)) {
      seen.add(key);
    } else if (!allowed.contains(key) && setsVersion(line)) {
      problems.add('`$line` overrides the version Flutter sets');
    }
  }
  for (final line in required) {
    if (!seen.contains(compact(line))) problems.add('lacks `$line`');
  }
  return problems;
}

/// [source] without its `/* */` and `//` comments, for the formats that
/// use C's (Kotlin, Windows resource scripts).
String _stripSlashComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
    .replaceAll(RegExp('//.*'), '');

/// Any identifier naming a version code or name, `versionNameSuffix` and
/// `setVersionCode` included, unless it reads Flutter's own value.
final _gradleVersionSetting = RegExp(
  r'(?<!flutter\.)\b\w*[vV]ersion(Code|Name)\w*',
);

/// Problems with an app's `build.gradle.kts` version settings.
///
/// Flutter's template sets the version in exactly two lines, and nothing
/// else in the file may touch it: a flavor's own `versionName`, a
/// `versionNameSuffix`, an output's `versionCodeOverride` and
/// `defaultConfig.versionCode = 3` all change what Android reports.
/// Reading `flutter.versionName` is fine.
List<String> _gradleVersionProblems(String source) =>
    _templateVersionProblems(_stripSlashComments(source).split('\n'), const [
      'versionCode = flutter.versionCode',
      'versionName = flutter.versionName',
    ], _gradleVersionSetting.hasMatch);

/// Problems with a Windows runner's `CMakeLists.txt`.
///
/// It must hand each of Flutter's version variables to the compiler as a
/// define. Without one, `Runner.rc` falls back to a hard-coded 1.0.0 and
/// the build still succeeds.
List<String> _cmakeVersionProblems(String source) => _templateVersionProblems(
  [for (final line in source.split('\n')) line.replaceFirst(RegExp('#.*'), '')],
  [
    r'target_compile_definitions(${BINARY_NAME} PRIVATE '
        r'"FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")',
    for (final part in const ['MAJOR', 'MINOR', 'PATCH', 'BUILD'])
      r'target_compile_definitions(${BINARY_NAME} PRIVATE '
          '"FLUTTER_VERSION_$part=\${FLUTTER_VERSION_$part}")',
  ],
  (line) => line.contains('FLUTTER_VERSION'),
);

/// Problems with a Windows runner's `Runner.rc`.
///
/// The template derives both of its version macros from Flutter's
/// defines, behind guards that test for them, and both numeric fields
/// and both version strings use them. Beyond those, only the template's
/// `#else` fallbacks may define the macros: a definition added after
/// them, an `#undef`, or one of Flutter's defines undone would win over
/// Flutter's while every template line stayed in place.
List<String> _rcVersionProblems(String source) => _templateVersionProblems(
  _stripSlashComments(source).split('\n'),
  const [
    '#if defined(FLUTTER_VERSION_MAJOR) && defined(FLUTTER_VERSION_MINOR) '
        '&& defined(FLUTTER_VERSION_PATCH) && defined(FLUTTER_VERSION_BUILD)',
    '#define VERSION_AS_NUMBER FLUTTER_VERSION_MAJOR,FLUTTER_VERSION_MINOR,'
        'FLUTTER_VERSION_PATCH,FLUTTER_VERSION_BUILD',
    '#if defined(FLUTTER_VERSION)',
    '#define VERSION_AS_STRING FLUTTER_VERSION',
    'FILEVERSION VERSION_AS_NUMBER',
    'PRODUCTVERSION VERSION_AS_NUMBER',
    r'VALUE "FileVersion", VERSION_AS_STRING "\0"',
    r'VALUE "ProductVersion", VERSION_AS_STRING "\0"',
  ],
  RegExp(
    r'^(FILEVERSION|PRODUCTVERSION)\b|^VALUE\s+"(File|Product)Version"'
    r'|^#\s*(define|undef)\s+(VERSION_AS_(NUMBER|STRING)|FLUTTER_VERSION\w*)\b',
  ).hasMatch,
  optional: const [
    '#define VERSION_AS_NUMBER 1,0,0,0',
    '#define VERSION_AS_STRING "1.0.0"',
  ],
);

/// Problems with an iOS or macOS `Info.plist`'s version entries.
///
/// XML comments are stripped first: the iOS one carries two, and an entry
/// inside one is not part of the plist. Xcode's General tab is a
/// reported way for a hand-set version to land here, as its Version and
/// Build fields can rewrite these entries.
List<String> _plistVersionProblems(String source) {
  final uncommented = source.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');
  final problems = <String>[];
  for (final (key, want) in const [
    ('CFBundleShortVersionString', r'$(FLUTTER_BUILD_NAME)'),
    ('CFBundleVersion', r'$(FLUTTER_BUILD_NUMBER)'),
  ]) {
    final entry = RegExp('<key>$key</key>\\s*<string>([^<]*)</string>');
    final matches = entry.allMatches(uncommented);
    if (matches.isEmpty) {
      problems.add('sets no $key string, expected ${_show(want)}');
    }
    for (final match in matches) {
      final actual = match.group(1)!;
      if (actual != want) {
        problems.add('$key is ${_show(actual)}, expected ${_show(want)}');
      }
    }
  }
  return problems;
}
