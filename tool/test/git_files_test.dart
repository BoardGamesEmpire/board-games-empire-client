// The shared git file listing that check_test_files, check_a11y_audit and
// check_decision_codes read (#808).
import 'dart:io';

import 'package:test/test.dart';

import '../src/git_files.dart';

void main() {
  late Directory tmp;
  late String repo;

  /// Runs git in [repo], with signing, hooks and the user's identity pinned
  /// so no prompt or global setting can reach the throwaway repository.
  ///
  /// Without git's own variables, too: run from a hook, `GIT_DIR` or
  /// `GIT_INDEX_FILE` would point the fixture's `add` and `commit` at the
  /// repository the hook belongs to.
  ProcessResult run(List<String> args, {bool check = true}) {
    final environment = Map.of(Platform.environment)
      ..removeWhere((name, _) => name.startsWith('GIT_'));
    final result = Process.runSync(
      'git',
      [
        '-c',
        'commit.gpgsign=false',
        '-c',
        'core.hooksPath=/dev/null',
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@example.invalid',
        ...args,
      ],
      workingDirectory: repo,
      environment: environment,
      includeParentEnvironment: false,
    );
    if (check && result.exitCode != 0) {
      fail('git ${args.join(' ')} failed:\n${result.stderr}');
    }
    return result;
  }

  void write(String path, String text) => (File(
    '$repo/$path',
  )..createSync(recursive: true)).writeAsStringSync(text);

  void commit(List<String> paths, String message) {
    run(['add', ...paths]);
    run(['commit', '-q', '-m', message]);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('git_files_');
    // git reports the top level with symlinks resolved, as macOS's temp
    // directory is one.
    repo = tmp.resolveSymbolicLinksSync();
    run(['init', '-q', '-b', 'main']);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('lists tracked and untracked files, not ignored ones', () {
    write('a.dart', '// a\n');
    write('.gitignore', 'c.dart\n');
    commit(['a.dart', '.gitignore'], 'a');
    write('b.dart', '// b\n');
    write('c.dart', '// c\n');

    final listing = checkoutFiles(['*.dart'], from: Directory(repo));

    expect(listing.paths, unorderedEquals(['a.dart', 'b.dart']));
  });

  test('lists from the top level when run from a subdirectory', () {
    write('a.dart', '// a\n');
    write('sub/d.dart', '// d\n');
    commit(['a.dart', 'sub/d.dart'], 'a');

    final listing = checkoutFiles(['*.dart'], from: Directory('$repo/sub'));

    expect(listing.top, repo);
    expect(listing.paths, containsAll(['a.dart', 'sub/d.dart']));
  });

  test('lists a conflicted path once', () {
    write('a.dart', 'base\n');
    commit(['a.dart'], 'base');
    run(['checkout', '-q', '-b', 'other']);
    write('a.dart', 'other\n');
    commit(['a.dart'], 'other');
    run(['checkout', '-q', 'main']);
    write('a.dart', 'main\n');
    commit(['a.dart'], 'main');
    final merge = run(['merge', '--no-edit', 'other'], check: false);
    expect(merge.exitCode, isNot(0), reason: 'the merge should conflict');

    final listing = checkoutFiles(['*.dart'], from: Directory(repo));

    expect(listing.paths.where((p) => p == 'a.dart'), hasLength(1));
  });

  test('throws GitFailed, rather than exiting, when git fails', () {
    expect(
      () => git(['no-such-command'], workingDirectory: repo),
      throwsA(
        isA<GitFailed>().having(
          (e) => e.message,
          'message',
          startsWith('git no-such-command failed:\n'),
        ),
      ),
    );
  });
}
