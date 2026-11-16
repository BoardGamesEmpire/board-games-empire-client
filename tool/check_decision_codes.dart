// Fails when a Dart, Markdown or YAML file cites a decision code (`Dn`, a `D`
// and one or two digits, or a decision by number in words) instead of the
// issue number alone (#377).
//
// A decision code names one of the decisions locked in an issue's analysis.
// It means something only next to that issue's text, so in source it is a
// reference nobody can follow once the issue moves on. Cite the issue
// (`#NNN`) and, where the sentence needs the decision, say what it decided.
// The codes belong in the tracker, which `docs/agents/` documents.
//
// Usage, from the workspace root:
//   dart run tool/check_decision_codes.dart               # exit 1 on a code
//   dart run tool/check_decision_codes.dart --self-test
//
// Elsewhere in the checkout, run `melos run check:decision-codes`, or give
// `dart run` the script's path from where you are. Both check the whole
// tree, as "Which files" below explains.
//
// Invoked by the `check:decision-codes` melos script and by CI, so both
// callers share one definition, the shape `check_test_files.dart` has.
//
// ── Which files ────────────────────────────────────────────────────
//
// The list comes from git: tracked files, plus untracked ones git does not
// ignore, limited to `*.dart`, `*.md`, `*.yaml` and `*.yml`. git is asked
// from the checkout's top level, so running this from inside a package
// still checks the whole tree. A path in conflict is listed once, not once
// per merge stage. The self-test pins all of this against a fixture
// repository.
//
// Two paths are exempt, by prefix. `docs/agents/` documents the convention
// and has to show codes. This file shows them in its fixtures and messages.
//
// ── What counts as a code ──────────────────────────────────────────
//
// A line is a hit when it holds a `D` followed by one or two digits, with no
// letter, digit or underscore on either side. That is a text match per line,
// not a parse: a citation wrapped onto a line of its own is still a code on
// that line, and is flagged. Colon-separated hex of three bytes or more,
// such as the certificate fingerprint `E0:30:D5:1C` in
// `tool/build_android.dart`, is deleted from the line first, so its `D5` is
// not read as a code. Three, not two, so a code before a colon and two hex
// characters (`D5:1C`, `D4:30`, `D1:D2`) is still read as a code. The run
// must stand alone too, so the strip never cuts the end off a longer token.
// It still hides a code inside a run of three or more (`D1:D2:D3`,
// `D5:1C:00`), which would pass. That is accepted: no such text exists.
//
// A line is also a hit when it cites a decision by number in words:
// "decision" or "decisions", then a digit, as in "design decision 4". It
// is the same lookup key spelled out. Only a number on the same line counts.

import 'dart:io';

import 'src/git_files.dart';
import 'src/self_test.dart';

/// Path prefixes this check never reports on. The files are still listed and
/// counted as checked.
const _exempt = ['docs/agents/', 'tool/check_decision_codes.dart'];

/// Three or more colon-separated hex bytes, such as a certificate
/// fingerprint, standing alone.
final _hexRun = RegExp(
  '(?<![0-9A-Za-z])[0-9A-F]{2}(?::[0-9A-F]{2}){2,}(?![0-9A-Za-z])',
);

/// A decision code: `D` and one or two digits, standing alone.
final _code = RegExp('(?<![A-Za-z0-9_])D[0-9]{1,2}(?![A-Za-z0-9_])');

/// A decision cited by number in words, such as "design decision 4".
final _decisionNumber = RegExp('(?<![A-Za-z0-9_])[Dd]ecisions?[ \t]+[0-9]');

Future<void> main(List<String> args) async {
  final unknown = args.where((a) => a != '--self-test');
  if (unknown.isNotEmpty) {
    stderr
      ..writeln('Unknown argument(s): ${unknown.join(', ')}')
      ..writeln('Usage: dart run tool/check_decision_codes.dart [--self-test]');
    exit(64); // EX_USAGE
  }

  if (args.contains('--self-test')) {
    await _selfTest();
    return;
  }

  final ({int checked, List<String> hits}) result;
  try {
    result = _scan(Directory.current.path);
  } on GitFailed catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final (:checked, :hits) = result;

  if (checked == 0) {
    // Not a pass: nothing was read, so a clean exit would report a tree
    // nobody examined. That is git listing nothing, or listing only files
    // deleted from the working tree.
    stderr.writeln(
      'No Dart, Markdown or YAML files were found on disk. Run this from a '
      'git checkout of the workspace.',
    );
    exit(1);
  }

  if (hits.isEmpty) {
    stdout.writeln('$checked files checked; no decision codes.');
    return;
  }

  hits.forEach(stderr.writeln);
  stderr.writeln(
    '\nCite the issue alone (#NNN). Decision codes belong in the tracker, '
    'not the source (#377).',
  );
  exit(1);
}

/// Checks every listed file of the git checkout that holds [cwd].
///
/// `checked` counts the files read, exempt ones included. Each of `hits` is
/// `path:line: text`, with the path relative to the checkout's top level.
({int checked, List<String> hits}) _scan(String cwd) {
  final (:top, :paths) = checkoutFiles([
    '*.dart',
    '*.md',
    '*.yaml',
    '*.yml',
  ], from: Directory(cwd));

  final hits = <String>[];
  var checked = 0;
  for (final path in paths) {
    // Listed by --cached but deleted from the working tree.
    final file = File('$top/$path');
    if (!file.existsSync()) continue;
    checked++;
    for (final (n, line) in _codeLines(path, file.readAsStringSync())) {
      hits.add('$path:$n: ${line.trim()}');
    }
  }
  return (checked: checked, hits: hits);
}

/// The lines of [source], read from [path], that cite a decision, each with
/// its 1-based number. Lines are split on newlines only. Empty for an exempt
/// path.
List<(int, String)> _codeLines(String path, String source) {
  if (_exempt.any(path.startsWith)) return const [];
  final lines = source.split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      if (_cites(lines[i])) (i + 1, lines[i]),
  ];
}

bool _cites(String line) =>
    _code.hasMatch(line.replaceAll(_hexRun, '')) ||
    _decisionNumber.hasMatch(line);

/// Fixture tests for [_codeLines] and [_scan].
///
/// This gate's failure mode is a silent pass: a pattern that stops matching,
/// or a file listing that stops including a file type, reports every tree
/// clean. So the shapes it must catch, the ones it must leave alone, and
/// the files it must read are pinned here. Run before the real check in CI.
Future<void> _selfTest() async {
  final selfTest = SelfTest('check_decision_codes');

  void expect(String name, String path, String source, List<int> expected) {
    final got = [for (final (n, _) in _codeLines(path, source)) n];
    selfTest.record(
      name,
      passed: got.join(',') == expected.join(','),
      detail: ': expected $expected, got $got',
    );
  }

  expect('flags #NNN Dn', 'p/lib/a.dart', '// per #63 D3 the x\n', [1]);
  expect('flags a bold code', 'p/lib/a.dart', '/// (#269 **D1**)\n', [1]);
  expect(
    'flags a wrapped bold code alone on a line',
    'p/lib/a.dart',
    '/// (#359\n/// **D2**, **D4**).\n',
    [2],
  );
  expect(
    'flags a bare code list',
    'p/lib/a.dart',
    '/// trigger (D1, D13): x\n',
    [1],
  );
  expect(
    'flags "decision Dn"',
    'p/lib/a.dart',
    '/// (#98, decision D10).\n',
    [1],
  );
  expect(
    'flags a code in a group name',
    'p/test/a_test.dart',
    "group('the current user role (D4)', () {\n",
    [1],
  );
  expect(
    'flags a code in a reason string',
    'p/test/a_test.dart',
    "expect(x, y, reason: 'D8: rejection never discards');\n",
    [1],
  );
  expect(
    'flags a hyphenated code',
    'p/test/a_test.dart',
    '// the D8-sensitive case\n',
    [1],
  );
  expect('flags YAML', 'p/pubspec.yaml', '# One package (#354 D1).\n', [1]);
  expect('flags Markdown', 'p/CHANGELOG.md', '- helpers (#354 D4).\n', [1]);
  expect(
    'passes a bare issue number',
    'p/lib/a.dart',
    '// per #63, the x\n',
    [],
  );
  expect(
    'passes a colon-separated fingerprint',
    'tool/build_android.dart',
    "  'E0:30:D5:1C:EB:13:E8:F9',\n",
    [],
  );
  expect(
    'passes letters around it',
    'p/lib/a.dart',
    '// MD5, ID3, D2D, 0xD5\n',
    [],
  );
  expect(
    'passes a code-shaped run fused to hex',
    'p/lib/a.dart',
    '// D5E0:30\n',
    [],
  );
  expect(
    'flags a code before a colon and a number',
    'p/lib/a.dart',
    '// D10:00\n',
    [1],
  );
  expect(
    'flags a code before a colon and one hex byte',
    'p/lib/a.dart',
    '// D5:1C\n',
    [1],
  );
  expect(
    'flags a colon-joined pair of codes',
    'p/lib/a.dart',
    '// D1:D2\n',
    [1],
  );
  expect(
    'flags a decision numbered in words',
    'p/lib/a.dart',
    '/// (#9 design decision 4).\n',
    [1],
  );
  expect(
    'flags a lettered decision number',
    'p/lib/a.dart',
    '/// ## Diagnostics (Decision 1a)\n',
    [1],
  );
  expect(
    'flags decisions numbered in a list',
    'p/test/a_test.dart',
    "test('x (decisions 2 and 3)', () {\n",
    [1],
  );
  expect(
    'passes "decision" with no number',
    'p/lib/a.dart',
    '// the decision to retry, made in 2 places\n',
    [],
  );
  expect('passes a digit before it', 'p/lib/a.dart', '// roll 1D6\n', []);
  expect('passes three digits', 'p/lib/a.dart', '// D123\n', []);
  expect('passes lowercase', 'p/lib/a.dart', '// d4\n', []);
  expect(
    'numbers lines by newline only, past a lone carriage return',
    'p/lib/a.dart',
    'a\rb\n// D4\n',
    [2],
  );
  expect(
    'exempts docs/agents',
    'docs/agents/issue-tracker.md',
    'cite as `#98 (D6)`\n',
    [],
  );
  expect(
    "exempts the check's own file",
    'tool/check_decision_codes.dart',
    "expect('x', 'p', '// #63 D3', [1]);\n",
    [],
  );

  await _selfTestScan(selfTest);
  selfTest.finish();
}

/// Fixture test for [_scan], against a throwaway git repository, recorded
/// in [selfTest].
///
/// The fixture holds a code in every file. The hits it must report are the
/// files the check reads; every other file shows what the listing leaves
/// out, and why.
Future<void> _selfTestScan(SelfTest selfTest) async {
  final root = Directory.systemTemp.createTempSync('check_decision_codes_');
  try {
    final dir = root.path;
    void write(String path, String text) =>
        (File('$dir/$path')..createSync(recursive: true)).writeAsStringSync(
          text,
        );

    git(['init', '-q'], workingDirectory: dir);
    write('a.dart', '// x\n// #1 D1\n');
    write('b.md', 'D2\n');
    write('c.yaml', '# D3\n');
    write('d.yml', '# D4\n');
    write('e.txt', 'D5\n'); // Not a listed type.
    write('docs/agents/f.md', 'D6\n'); // Exempt, but read.
    write('gone.md', 'D7\n'); // Tracked, then deleted from disk.
    write('.gitignore', 'ignored.md\n');
    write('ignored.md', 'D8\n'); // Ignored and untracked.
    git([
      'add',
      'a.dart',
      'b.md',
      'c.yaml',
      'd.yml',
      'e.txt',
      'docs/agents/f.md',
      'gone.md',
      '.gitignore',
    ], workingDirectory: dir);
    File('$dir/gone.md').deleteSync();
    write('pkg/sub/new.md', 'D9\n'); // Untracked, not ignored.

    // A path in conflict: in the index at stages 1, 2 and 3.
    write('m.md', 'D10\n');
    final blob = git([
      'hash-object',
      '-w',
      'm.md',
    ], workingDirectory: dir).trim();
    final index = await Process.start(
      'git',
      ['update-index', '--index-info'],
      workingDirectory: dir,
    );
    index.stdin.write(
      [
        for (final stage in [1, 2, 3]) '100644 $blob $stage\tm.md\n',
      ].join(),
    );
    await index.stdin.close();
    final indexOut = index.stdout.drain<void>();
    final indexErr = index.stderr.transform(systemEncoding.decoder).join();
    if (await index.exitCode != 0) {
      stderr.writeln('git update-index failed:\n${await indexErr}');
      exit(1);
    }
    await indexOut;

    // From inside a package, as `melos run` would.
    final (:checked, :hits) = _scan('$dir/pkg/sub');
    final got = (hits.toList()..sort()).join('\n');
    const want = [
      'a.dart:2: // #1 D1',
      'b.md:1: D2',
      'c.yaml:1: # D3',
      'd.yml:1: # D4',
      'm.md:1: D10',
      'pkg/sub/new.md:1: D9',
    ];
    selfTest
      ..record(
        'lists every type, the whole tree from a package, untracked files '
        'once, each conflicted path once; skips ignored, deleted, exempt and '
        'unlisted files',
        passed: got == want.join('\n'),
        detail: ': expected\n${want.join('\n')}\ngot\n$got',
      )
      // a, b, c, d, docs/agents/f, m and pkg/sub/new.
      ..record(
        'counts each file read once, exempt ones too',
        passed: checked == 7,
        detail: ': expected 7, got $checked',
      );
  } finally {
    root.deleteSync(recursive: true);
  }
}
