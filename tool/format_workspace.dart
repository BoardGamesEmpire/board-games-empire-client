// Formats — or, with `--check`, verifies the formatting of — every Dart
// file tracked by git (#173).
//
// Usage, from the workspace root:
//   dart run tool/format_workspace.dart            # rewrite in place
//   dart run tool/format_workspace.dart --check    # exit 1 on any drift
//
// Run from anywhere else it exits 1 rather than proceeding — see
// [_requireWorkspaceRoot], where the reason is not fussiness.
//
// Invoked by the `format` / `format:check` melos scripts and by CI's
// `format` job. It exists so both callers share one definition without CI
// having to run melos, which it deliberately does not do — the same shape
// as `check_sdk_constraints.dart`.
//
// ── Why the file list comes from git ───────────────────────────────
//
// `dart format` has no --exclude and does not read .gitignore, so handing
// it directories formats whatever happens to be on disk. Asking git
// instead pins the set to what is tracked, which matters three times over:
//
//   * 49 `build/` directories sit INSIDE packages/ and apps/. Naming
//     those directories excludes nothing — only a root-level `build/`
//     would be skipped — so build output could fail the gate with no
//     source-level fix.
//   * The generated sources (.g.dart, .freezed.dart, gen-l10n output) are
//     gitignored: present on a developer's disk, absent in CI. A
//     directory walk therefore checks a different set in each place, and
//     "mirrors CI" would be false.
//   * A directory list has to be kept in step by hand. Anything added
//     outside it is silently ungated, which is the drift #173 exists to
//     stop.
//
// The cost is that a brand-new file goes unchecked until `git add`. The
// index is what CI will see, so that is the right boundary.
//
// ── Why this is a Dart script and not a shell pipeline ─────────────
//
// The obvious form is `git ls-files -z '*.dart' | xargs -0 dart format`,
// which is what this replaced. It is correct and it is unrunnable on
// Windows: `xargs` is not present under cmd or PowerShell. Making the one
// gate every contributor must satisfy POSIX-only would leave a Windows
// contributor with a red CI job and no local way to reproduce it.
//
// ── Why the batching ───────────────────────────────────────────────
//
// Windows caps a command line at 32,767 wide characters. The tracked set
// is already ~27,000 of them in paths alone and only grows, so passing
// them in one invocation would begin failing on Windows without warning.
// Batches are sized by command-line length rather than file count because
// path lengths vary. Every batch runs even after one reports drift or
// fails, so `--check` reports the whole list rather than the first
// batch's worth.

import 'dart:io';

/// Conservative ceiling for one `dart format` invocation's argument list,
/// measured in UTF-16 code units.
///
/// That unit is not an approximation of the real constraint, it *is* the
/// real constraint: `CreateProcess` caps `lpCommandLine` at 32,767 wide
/// characters, and Dart's `String.length` counts exactly those. Measuring
/// UTF-8 bytes instead would be the wrong budget on any non-ASCII path.
///
/// The gap to 32,767 leaves room for the executable path, the flags, and
/// the process environment without needing to model any of them.
const _maxCommandLineUnits = 24000;

/// git's `-z` separator. Written as a code unit rather than an escape so
/// the byte is unambiguous in source.
final _nul = String.fromCharCode(0);

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final unknown = args.where((a) => a != '--check').toList();
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln('Usage: dart run tool/format_workspace.dart [--check]');
    exit(64); // EX_USAGE
  }

  _requireWorkspaceRoot();

  final files = _trackedDartFiles();
  if (files.isEmpty) {
    // Not a success: it means git returned nothing, which is either a
    // detached/empty checkout or a bad invocation. Formatting "all zero"
    // files would report a clean gate on an unexamined tree.
    stderr.writeln(
      'No tracked .dart files found. Run this from a git checkout of the '
      'workspace root.',
    );
    exit(1);
  }

  var drifted = false;
  var failure = 0;

  for (final batch in _batch(files)) {
    final process = await Process.start('dart', [
      'format',
      if (check) ...['--output=none', '--set-exit-if-changed'],
      ...batch,
    ], mode: ProcessStartMode.inheritStdio);
    final code = await process.exitCode;
    if (code == 0) continue;

    // Exit 1 means "would be reformatted", and ONLY when
    // --set-exit-if-changed asked for it. Anything else is the formatter
    // failing — a syntax error is 65 — and must not be reported as drift,
    // because "run `melos run format`" is useless advice for a file that
    // does not parse. Without this split, write mode was worse still: it
    // set the same flag and then exited 0, so a failed format looked like
    // a successful one.
    //
    // The split is as sharp as `dart format` allows, not sharper: given a
    // batch holding both an unparseable file and a drifted one, it prints
    // the parse error but still exits 1, so that batch reads as drift.
    // The error text is on stderr either way — only the exit code and the
    // closing summary lose the distinction.
    if (check && code == 1) {
      drifted = true;
    } else {
      // Keep the first real failure, and keep going: a broken file in one
      // batch should not hide drift in another.
      if (failure == 0) failure = code;
    }
  }

  if (failure != 0) {
    stderr.writeln(
      '\ndart format exited $failure. That is a formatter failure, not a '
      'formatting difference — the output above names the file.',
    );
    exit(failure);
  }

  if (check && drifted) {
    stderr.writeln(
      '\n${files.length} tracked Dart files checked; some are not formatted. '
      'Run `melos run format` (or `dart run tool/format_workspace.dart`) and '
      'commit the result.',
    );
    exit(1);
  }
}

/// Exits unless the current directory is the git checkout's top level.
///
/// `git ls-files` scopes its pathspec to the working directory, so from
/// `packages/features/auth` this script matches 19 files instead of 499,
/// formats them, and reports the workspace clean. A gate that passes by
/// examining 4% of the tree is worse than no gate, because the green exit
/// is indistinguishable from a real one.
///
/// Checked against `git rev-parse --show-toplevel` rather than the
/// presence of a `pubspec.yaml` — the check `check_sdk_constraints.dart`
/// uses — because every package directory has one of those, so that test
/// would pass in exactly the directories this needs to reject. Comparing
/// against git's own notion of the root also targets the mechanism that
/// causes the bug rather than a proxy for it.
void _requireWorkspaceRoot() {
  final result = Process.runSync('git', ['rev-parse', '--show-toplevel']);
  if (result.exitCode != 0) {
    stderr.writeln(
      'Not inside a git checkout, so the tracked file list is '
      'unavailable:\n${result.stderr}',
    );
    exit(1);
  }

  final top = (result.stdout as String).trim();
  if (_samePath(top, Directory.current.path)) return;

  stderr.writeln(
    'Run this from the workspace root.\n'
    '  root: $top\n'
    '  here: ${Directory.current.path}\n\n'
    '`git ls-files` scopes its pathspec to the working directory, so from '
    'here it would silently check only this subtree and report the '
    'workspace formatted.',
  );
  exit(1);
}

/// Whether two paths name the same directory.
///
/// Resolved through symlinks because macOS hands out `/tmp` for
/// `/private/tmp`, and compared case-insensitively on Windows, where the
/// two spellings of a path are the same directory.
bool _samePath(String a, String b) {
  String canonical(String p) {
    final resolved = Directory(p).resolveSymbolicLinksSync();
    return Platform.isWindows ? resolved.toLowerCase() : resolved;
  }

  try {
    return canonical(a) == canonical(b);
  } on FileSystemException {
    return false;
  }
}

/// Every `.dart` path git is tracking, relative to the current directory.
///
/// `-z` because a NUL separator is the only one a filename cannot contain;
/// splitting on newlines would corrupt any path containing one.
List<String> _trackedDartFiles() {
  final result = Process.runSync('git', ['ls-files', '-z', '*.dart']);
  if (result.exitCode != 0) {
    stderr.writeln('git ls-files failed:\n${result.stderr}');
    exit(1);
  }
  return (result.stdout as String)
      .split(_nul)
      .where((p) => p.isNotEmpty)
      .toList();
}

/// Splits [files] into groups whose joined length stays under
/// [_maxCommandLineUnits]. A single path longer than the budget still gets
/// its own batch rather than being dropped.
Iterable<List<String>> _batch(List<String> files) sync* {
  var current = <String>[];
  var size = 0;
  for (final f in files) {
    final cost = f.length + 1; // +1 for the separator
    if (current.isNotEmpty && size + cost > _maxCommandLineUnits) {
      yield current;
      current = <String>[];
      size = 0;
    }
    current.add(f);
    size += cost;
  }
  if (current.isNotEmpty) yield current;
}
