import 'dart:io';

/// git's `-z` separator. Written as a code unit rather than an escape so
/// the byte is unambiguous in source.
final _nul = String.fromCharCode(0);

/// Runs git with [args] and returns its stdout. Throws [GitFailed] when git
/// exits non-zero.
String git(List<String> args, {String? workingDirectory}) {
  final result = Process.runSync(
    'git',
    args,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    throw GitFailed(args.first, result.stderr as String);
  }
  return result.stdout as String;
}

/// A git command exited non-zero.
///
/// Thrown rather than exiting, so a failure under `dart test` fails one test
/// instead of ending the run. Each checker prints [message] and exits 1.
final class GitFailed implements Exception {
  /// git's [command] failed, and wrote [stderr].
  GitFailed(String command, String stderr)
    : message = 'git $command failed:\n$stderr';

  /// What to tell the person who ran the script.
  final String message;

  @override
  String toString() => message;
}

/// The files matching [pathspecs] in the git checkout that holds [from], the
/// current directory by default (#808).
///
/// `top` is the checkout's top level, and each of `paths` is relative to it.
/// The paths are the tracked files, deleted ones included, and the
/// untracked ones git doesn't ignore, each listed once. Throws [GitFailed]
/// when git does.
({String top, List<String> paths}) checkoutFiles(
  List<String> pathspecs, {
  Directory? from,
}) {
  final top = git([
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: from?.path).trim();
  // From [top], because `git ls-files` scopes its pathspec to the working
  // directory: run from inside a package it would list only that package.
  final paths = git(
    [
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
      // A conflicted path is otherwise listed once per merge stage.
      '--deduplicate',
      '--',
      ...pathspecs,
    ],
    workingDirectory: top,
  ).split(_nul).where((p) => p.isNotEmpty).toList();
  return (top: top, paths: paths);
}
