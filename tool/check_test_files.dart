// Fails when a Dart file under a `test/` directory declares a `main` but is
// not named `*_test.dart` (#197).
//
// `flutter test` runs only files whose names end in `_test.dart`. Anything
// else under `test/` is treated as support code, which is right for fakes
// and fixtures. A file with a `main` is a suite, though, and a suite with
// the wrong name is skipped without a word: its tests exist, read as
// coverage, and never run. `models`' achievement tests sat like that until
// #197 renamed the file.
//
// Usage, from anywhere in the checkout:
//   dart run tool/check_test_files.dart               # exit 1 on a misnamed suite
//   dart run tool/check_test_files.dart --self-test
//
// Invoked by the `check:test-files` melos script and by CI's `test-files`
// job, so both callers share one definition. That is the same shape as
// `format_workspace.dart`.
//
// ── Which files ────────────────────────────────────────────────────
//
// The list comes from git: tracked files, plus untracked ones git does not
// ignore. So a new suite fails here before `git add`, and generated sources
// stay out. git is asked from the checkout's top level, and paths are read
// from there too, so running this from inside a package still checks the
// whole tree. `format_workspace.dart` refuses to run anywhere but the root
// for want of exactly that.
//
// ── What counts as a main ──────────────────────────────────────────
//
// A line that starts, at column 0, with `main(` or a return type followed
// by `main(`. That is a text match, not a parse, which keeps this script
// free of package dependencies. The formatter puts every top-level
// declaration at column 0, so a real `main` cannot hide from it. What it
// can do is match inside a multi-line string, and that fails loudly, which
// is the safe direction for a gate to be wrong in.

import 'dart:io';

/// git's `-z` separator. Written as a code unit rather than an escape so
/// the byte is unambiguous in source.
final _nul = String.fromCharCode(0);

/// A top-level `main(`, bare or after a return type such as `void` or
/// `Future<void>`.
final _main = RegExp(r'^(?:\w[\w<>?, ]*\s+)?main\s*\(', multiLine: true);

void main(List<String> args) {
  final unknown = args.where((a) => a != '--self-test');
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln('Usage: dart run tool/check_test_files.dart [--self-test]');
    exit(64); // EX_USAGE
  }

  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }

  final top = _git(['rev-parse', '--show-toplevel']).trim();
  // From [top], because `git ls-files` scopes its pathspec to the working
  // directory: run from inside a package it would list only that package.
  final underTest = _git(
    [
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
      '--',
      '*.dart',
    ],
    workingDirectory: top,
  ).split(_nul).where((p) => p.isNotEmpty && _isUnderTest(p)).toList();

  if (underTest.isEmpty) {
    // Not a pass: git returned nothing to check, so a clean exit would
    // report a tree nobody examined.
    stderr.writeln(
      'No Dart files under a test/ directory were found. Run this from a git '
      'checkout of the workspace.',
    );
    exit(1);
  }

  final misnamed = <String>[];
  for (final path in underTest) {
    // Listed by --cached but deleted from the working tree.
    final file = File('$top/$path');
    if (!file.existsSync()) continue;
    if (_isMisnamedSuite(path, file.readAsStringSync())) misnamed.add(path);
  }

  if (misnamed.isEmpty) {
    stdout.writeln(
      '${underTest.length} Dart files under test/ checked; every one with a '
      'main is named *_test.dart.',
    );
    return;
  }

  stderr.writeln(
    '${misnamed.length} file(s) under test/ declare a main but are not named '
    '*_test.dart, so `flutter test` never runs them:',
  );
  for (final path in misnamed) {
    stderr.writeln('  $path');
  }
  stderr.writeln(
    '\nRename each to end in _test.dart. If one is support code rather than '
    'a suite, remove its main.',
  );
  exit(1);
}

/// Runs git and returns its stdout, exiting with git's error if it fails.
String _git(List<String> args, {String? workingDirectory}) {
  final result = Process.runSync(
    'git',
    args,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    stderr.writeln('git ${args.first} failed:\n${result.stderr}');
    exit(1);
  }
  return result.stdout as String;
}

/// Whether [path] sits anywhere below a directory named `test`.
///
/// git separates paths with `/` on every platform, Windows included.
bool _isUnderTest(String path) {
  final segments = path.split('/');
  return segments.sublist(0, segments.length - 1).contains('test');
}

/// Whether [path] is a suite `flutter test` would skip: under `test/`, not
/// named `*_test.dart`, and declaring a `main`.
bool _isMisnamedSuite(String path, String source) =>
    _isUnderTest(path) &&
    !path.endsWith('_test.dart') &&
    _main.hasMatch(source);

/// Fixture tests for [_isMisnamedSuite].
///
/// This gate's failure mode is a silent pass: a pattern that stops matching
/// reports every tree clean, and the workspace cannot show it, because the
/// workspace holds no misnamed suite for it to catch. So the shapes it must
/// catch, and the ones it must leave alone, are pinned here. Run by the
/// `test-files` CI job.
void _selfTest() {
  var failures = 0;

  void expect(String name, String path, String source, bool misnamed) {
    if (_isMisnamedSuite(path, source) == misnamed) {
      stdout.writeln('  ok   $name');
    } else {
      failures++;
      stdout.writeln('  FAIL $name: expected misnamed=$misnamed');
    }
  }

  const suite = 'void main() {\n  test("x", () {});\n}\n';

  expect('flags a suite without the suffix', 'p/test/a.dart', suite, true);
  expect('flags one at the repo root', 'test/a.dart', suite, true);
  expect('flags one nested deeper', 'p/test/x/y/a.dart', suite, true);
  expect(
    'flags an async main',
    'p/test/a.dart',
    'Future<void> main() async {}\n',
    true,
  );
  expect('flags a bare main', 'p/test/a.dart', 'main() {}\n', true);
  expect(
    'flags a main that takes arguments',
    'p/test/a.dart',
    'FutureOr<void> main(List<String> args) {}\n',
    true,
  );
  expect(
    'flags a main below imports and helpers',
    'p/test/a.dart',
    "import 'x.dart';\n\nclass Fake {}\n\n$suite",
    true,
  );
  expect('passes a named suite', 'p/test/a_test.dart', suite, false);
  expect(
    'passes support code',
    'p/test/support/fakes.dart',
    'class Fake {\n  void run() {}\n}\n',
    false,
  );
  expect('passes a main outside test/', 'p/lib/a.dart', suite, false);
  expect('passes a test-like dir name', 'p/testing/a.dart', suite, false);
  expect(
    'passes a flutter_test_config',
    'p/test/flutter_test_config.dart',
    'Future<void> testExecutable(FutureOr<void> Function() main) async {}\n',
    false,
  );
  expect(
    'passes a longer name starting with main',
    'p/test/a.dart',
    'void mainly() {}\n',
    false,
  );
  expect(
    'passes a commented-out main',
    'p/test/a.dart',
    '// void main() {}\n',
    false,
  );
  expect(
    'passes an indented call to main',
    'p/test/a.dart',
    'void run() {\n  main();\n}\n',
    false,
  );

  if (failures > 0) {
    stderr.writeln('\n$failures self-test failure(s).');
    exit(1);
  }
  stdout.writeln('check_test_files self-test passed.');
}
