// Verifies the pubspec invariants that hold across every package in the
// workspace. Two of them today:
//
//   1. SDK constraints match the root pubspec (#153) — the bulk of this
//      file, and the one `--fix` can repair.
//   2. Every pubspec, root included, declares `publish_to: none` (#156).
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
// ── Coverage ───────────────────────────────────────────────────────
//
// Packages are discovered from the root `workspace:` list, not from
// disk, so a package that exists but is not listed is invisible to both
// invariants. That is the right trade — an unlisted package is not part
// of the resolve — but do not read this as "every package on disk".
//
// Usage:
//   dart run tool/check_sdk_constraints.dart          # report, exit 1 on drift
//   dart run tool/check_sdk_constraints.dart --fix    # rewrite SDK offenders
//   dart run tool/check_sdk_constraints.dart --self-test
//
// Bumping the toolchain is therefore: edit the root `environment:`
// block, then run with `--fix`.

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

  final members = (rootYaml['workspace'] as YamlList?)?.cast<String>();
  if (members == null || members.isEmpty) {
    stderr.writeln('Root pubspec.yaml lists no `workspace:` members.');
    exit(1);
  }

  final problems = <String>[];
  final publishProblems = <String>[];
  final unfixable = <String>[];
  var fixed = 0;

  // The root is a real package too — `dart pub publish` from here would
  // target `board_games_empire` — so it gets the publish_to check even
  // though it is not one of its own `workspace:` members.
  _checkPublishTo('pubspec.yaml', rootYaml, publishProblems);

  for (final dir in members) {
    final path = '$dir/pubspec.yaml';
    final file = File(path);
    if (!file.existsSync()) {
      problems.add('$path: listed in `workspace:` but does not exist');
      continue;
    }

    final source = file.readAsStringSync();
    final yaml = loadYaml(source) as YamlMap;

    // Before the environment checks, which `continue` past this point.
    _checkPublishTo(path, yaml, publishProblems);

    final env = yaml['environment'] as YamlMap?;
    if (env == null) {
      problems.add('$path: has no `environment:` block');
      continue;
    }

    final wantFlutter = _usesFlutterSdk(yaml) ? expectedFlutter : null;
    final actualSdk = env['sdk']?.toString();
    final actualFlutter = env['flutter']?.toString();

    if (actualSdk == expectedSdk && actualFlutter == wantFlutter) continue;

    if (actualSdk != expectedSdk) {
      problems.add(
        '$path: sdk is ${_show(actualSdk)}, expected ${_show(expectedSdk)}',
      );
    }
    if (actualFlutter != wantFlutter) {
      problems.add(
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
        fixed++;
      }
    }
  }

  // Reported before the SDK results and never repaired by --fix, so it
  // gets its own exit path. Folding it into `problems` would make --fix
  // claim to have rewritten something it cannot touch.
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

  if (problems.isEmpty) {
    if (publishProblems.isNotEmpty) exit(1);
    stdout.writeln(
      'Workspace pubspec invariants hold across ${members.length} packages '
      'plus the root (Flutter $pin, sdk $expectedSdk, publish_to none).',
    );
    return;
  }

  if (fix) {
    stdout.writeln('Rewrote $fixed pubspec(s):');
    for (final p in problems) {
      stdout.writeln('  $p');
    }
    if (unfixable.isNotEmpty) {
      stderr.writeln('\nCould not rewrite ${unfixable.length} pubspec(s):');
      for (final p in unfixable) {
        stderr.writeln('  $p');
      }
      exit(1);
    }
    if (publishProblems.isNotEmpty) exit(1);
    stdout.writeln('Run `flutter pub get` to re-resolve.');
    return;
  }

  stderr.writeln(
    'SDK constraint drift against the root pin (Flutter $pin, '
    'sdk $expectedSdk):',
  );
  for (final p in problems) {
    stderr.writeln('  $p');
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

/// Fixture tests for [_rewriteEnvironment].
///
/// The rewriter's failure mode is a silent no-op — it returns something
/// plausible, `--fix` reports success, and the drift is still there on the
/// next run. That is invisible to the workspace check itself, because the
/// workspace only ever holds already-correct pubspecs. So the shapes it
/// has to survive are pinned here instead. Run by the `constraints` CI job.
void _selfTest() {
  const sdk = '^3.12.0';
  const flutter = '>=3.44.4';
  var failures = 0;

  void expect(String name, String? actual, String? expected) {
    if (actual == expected) {
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
  final lines = source.split('\n');
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
  ].join('\n');
}
