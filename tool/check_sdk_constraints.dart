// Verifies that every workspace package declares the same SDK
// constraints, derived from the root pubspec (#153).
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
// Usage:
//   dart run tool/check_sdk_constraints.dart          # report, exit 1 on drift
//   dart run tool/check_sdk_constraints.dart --fix    # rewrite offenders
//
// Bumping the toolchain is therefore: edit the root `environment:`
// block, then run with `--fix`.

import 'dart:io';

import 'package:yaml/yaml.dart';

void main(List<String> args) {
  final fix = args.contains('--fix');
  final unknown = args.where((a) => a != '--fix');
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln('Usage: dart run tool/check_sdk_constraints.dart [--fix]');
    exit(64); // EX_USAGE
  }

  final root = File('pubspec.yaml');
  if (!root.existsSync()) {
    stderr.writeln(
      'pubspec.yaml not found. Run this from the workspace root.',
    );
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
  var fixed = 0;

  for (final dir in members) {
    final path = '$dir/pubspec.yaml';
    final file = File(path);
    if (!file.existsSync()) {
      problems.add('$path: listed in `workspace:` but does not exist');
      continue;
    }

    final source = file.readAsStringSync();
    final yaml = loadYaml(source) as YamlMap;
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
      file.writeAsStringSync(
        _rewriteEnvironment(source, expectedSdk, wantFlutter),
      );
      fixed++;
    }
  }

  if (problems.isEmpty) {
    stdout.writeln(
      'SDK constraints consistent across ${members.length} workspace '
      'packages (Flutter $pin, sdk $expectedSdk).',
    );
    return;
  }

  if (fix) {
    stdout.writeln('Rewrote $fixed pubspec(s):');
    for (final p in problems) {
      stdout.writeln('  $p');
    }
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
  stderr.writeln(
    '\nFix with: dart run tool/check_sdk_constraints.dart --fix',
  );
  exit(1);
}

String _show(String? value) => value == null ? '(absent)' : '"$value"';

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

/// Rewrites the `environment:` block in place.
///
/// Edits raw lines rather than round-tripping through the YAML writer,
/// which would drop every comment in the file.
String _rewriteEnvironment(String source, String sdk, String? flutter) {
  final lines = source.split('\n');
  final start = lines.indexWhere((l) => l.trimRight() == 'environment:');
  if (start == -1) return source;

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
  final indent = RegExp(r'^(\s+)').firstMatch(
        block.firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '  x',
        ),
      )?.group(1) ??
      '  ';

  final rebuilt = <String>[];
  var wroteFlutter = false;
  for (final line in block) {
    if (RegExp(r'^\s*sdk:').hasMatch(line)) {
      rebuilt.add('${indent}sdk: $sdk');
      // Keep `flutter:` adjacent to `sdk:` when introducing it.
      if (flutter != null && !block.any(_isFlutterLine)) {
        rebuilt.add('${indent}flutter: "$flutter"');
        wroteFlutter = true;
      }
    } else if (_isFlutterLine(line)) {
      if (flutter != null) {
        rebuilt.add('${indent}flutter: "$flutter"');
        wroteFlutter = true;
      }
      // else: drop the line — the package is Flutter-free.
    } else {
      rebuilt.add(line);
    }
  }

  // Only possible if the block had no `sdk:` line to anchor to.
  if (flutter != null && !wroteFlutter) {
    rebuilt.insert(0, '${indent}flutter: "$flutter"');
  }

  return [...lines.sublist(0, start + 1), ...rebuilt, ...lines.sublist(end)]
      .join('\n');
}

bool _isFlutterLine(String line) => RegExp(r'^\s*flutter:').hasMatch(line);
