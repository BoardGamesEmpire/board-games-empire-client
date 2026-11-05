// Fails when a screen has no accessibility-audit test group (#50).
//
// Every `*_screen.dart` under a package's `lib/` must be audited: the same
// package's `test/` tree needs a `*_test.dart` that holds both
// `group('accessibility audit'` and the screen's class name. The audit
// itself (`auditScreen` in `bge_test_support`) is what finds contrast,
// tap-target and label failures; this script only makes sure no screen
// escapes it, so a new screen fails here until someone writes its group.
//
// Usage, from the workspace root:
//   dart run tool/check_a11y_audit.dart               # exit 1 on an unaudited screen
//   dart run tool/check_a11y_audit.dart --self-test
//
// Elsewhere in the checkout, run `melos run check:a11y-audit`, or give
// `dart run` the script's path from where you are. Both check the whole
// tree.
//
// Invoked by the `check:a11y-audit` melos script and by CI's `test-files`
// job, so both callers share one definition, as `check_test_files.dart`
// does.
//
// ── Which files ────────────────────────────────────────────────────
//
// The list comes from git: tracked files, plus untracked ones git does not
// ignore, asked from the checkout's top level. So a new screen fails here
// before `git add`, and `.dart_tool` and generated sources stay out
// without a special case.
//
// ── What counts as audited ─────────────────────────────────────────
//
// The class name is the file name in Pascal case: `server_add_screen.dart`
// is `ServerAddScreen`. The match is a text match, not a parse, which
// keeps this script free of package dependencies. It can be wrong in the
// passing direction: a test that names the class and the group in a
// comment, or in two unrelated places, counts, and so does a group that is
// skipped. A skip carries its tracked finding, which is how a known gap is
// kept visible; a group that really audits the screen is what the reviewer
// checks. This gate catches the screen nobody thought of. It cannot be wrong the other way for a screen whose
// audit follows the convention: the class name is matched as a whole word,
// so `HouseholdScreen` is not satisfied by `HouseholdScreenView`.
//
// ── Exemptions ─────────────────────────────────────────────────────
//
// [_deferred] lists screens other units are rewriting. They are printed on
// every run so they cannot be forgotten. It is keyed by the screen's path
// from the workspace root, so a screen of the same name in another package
// is not exempt with it, and an entry that matches no screen file is stale
// and fails the check, so a rename, a move or a deletion cannot leave a
// silent exemption behind. The map is
// emptied once those units merge and their screens gain audit groups.

import 'dart:io';

/// git's `-z` separator. Written as a code unit rather than an escape so
/// the byte is unambiguous in source.
final _nul = String.fromCharCode(0);

/// Screens exempt for now, by path from the workspace root, with the unit
/// that owns the rewrite. #50 closes this map when those units merge.
const _deferred = {
  'packages/features/household/lib/src/screens/household_detail_screen.dart':
      '#479/#478 in flight',
  'packages/features/household/lib/src/screens/household_list_screen.dart':
      '#479/#478 in flight',
  'packages/features/data_gateway/lib/src/screens/data_gateway_list_screen.dart':
      '#479/#478 in flight',
  'packages/features/data_gateway/lib/src/screens/data_gateway_form_screen.dart':
      '#479/#478 in flight',
  'packages/features/data_gateway/lib/src/screens/data_gateway_detail_screen.dart':
      '#479/#478 in flight',
  'packages/features/events/lib/src/screens/event_detail_screen.dart':
      '#508/#667 in flight',
  'packages/features/catalog/lib/src/screens/game_detail_screen.dart':
      '#708/#709/#735 in flight',
  'packages/features/collection/lib/src/screens/game_collection_list_screen.dart':
      '#708/#709/#735 in flight',
  'packages/features/collection/lib/src/entry/collection_entry_screen.dart':
      '#708/#709/#735 in flight',
};

const _groupLiteral = "group('accessibility audit'";

/// A screen with no audit group.
class Uncovered {
  const Uncovered(this.path, this.className);

  final String path;
  final String className;

  @override
  String toString() => '$path \u{2192} $className';
}

/// What [checkAudit] found.
class AuditResult {
  const AuditResult({
    required this.screens,
    required this.uncovered,
    required this.exempt,
    required this.stale,
  });

  /// Screen files seen, exempt ones included.
  final int screens;

  /// Screens that are neither audited nor exempt.
  final List<Uncovered> uncovered;

  /// Exempt screens found: path to reason.
  final Map<String, String> exempt;

  /// [_deferred]-style keys that match no screen file.
  final List<String> stale;

  bool get ok => uncovered.isEmpty && stale.isEmpty;
}

void main(List<String> args) {
  final unknown = args.where((a) => a != '--self-test');
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln('Usage: dart run tool/check_a11y_audit.dart [--self-test]');
    exit(64); // EX_USAGE
  }

  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }

  final top = _git(['rev-parse', '--show-toplevel']).trim();
  // From [top], because `git ls-files` scopes its pathspec to the working
  // directory: run from inside a package it would list only that package.
  final paths = _git([
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
    '--',
    '*.dart',
  ], workingDirectory: top).split(_nul).where((p) => p.isNotEmpty).toList();

  final result = checkAudit(top, paths, _deferred);

  if (result.screens == 0) {
    // Not a pass: nothing was examined.
    stderr.writeln(
      'No *_screen.dart files under packages/*/lib were found on disk. Run '
      'this from a git checkout of the workspace.',
    );
    exit(1);
  }

  if (result.exempt.isNotEmpty) {
    stdout.writeln(
      '${result.exempt.length} screen(s) exempt until their units merge:',
    );
    for (final e in result.exempt.entries) {
      stdout.writeln('  ${e.key}  (${e.value})');
    }
  }

  if (result.ok) {
    stdout.writeln(
      '${result.screens} screens checked; every one is audited or exempt.',
    );
    return;
  }

  if (result.stale.isNotEmpty) {
    stderr.writeln(
      '${result.stale.length} exemption(s) in _deferred match no screen '
      'file. Remove or rename them:',
    );
    for (final s in result.stale) {
      stderr.writeln('  $s');
    }
  }
  if (result.uncovered.isNotEmpty) {
    stderr.writeln(
      "${result.uncovered.length} screen(s) have no group('accessibility "
      "audit') naming their class in their package's test/:",
    );
    for (final u in result.uncovered) {
      stderr.writeln('  $u');
    }
    stderr.writeln(
      "\nAdd a group('accessibility audit', ...) that calls auditScreen for "
      'each screen, in a *_test.dart under the same package.',
    );
  }
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

/// `server_add_screen.dart` to `ServerAddScreen`.
String classNameOf(String basename) => basename
    .substring(0, basename.length - '.dart'.length)
    .split('_')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join();

/// The package directory of a screen at [path], or null when [path] is not
/// a `*_screen.dart` below `packages/**/lib/`.
String? _packageOf(String path) {
  if (!path.startsWith('packages/') || !path.endsWith('_screen.dart')) {
    return null;
  }
  final segments = path.split('/');
  final lib = segments.indexOf('lib');
  // The file itself is the last segment, so `lib` must precede it.
  if (lib < 1 || lib >= segments.length - 1) return null;
  return segments.sublist(0, lib).join('/');
}

/// Whether [path] is a `*_test.dart` below `<package>/test/`.
bool _isSuiteOf(String package, String path) =>
    path.startsWith('$package/test/') && path.endsWith('_test.dart');

/// Applies the rule to [paths] (git-style, `/`-separated, relative to
/// [top]), reading file contents from [top].
AuditResult checkAudit(
  String top,
  List<String> paths,
  Map<String, String> deferred,
) {
  // Test sources by package, read once and only for suites.
  final sources = <String, List<String>>{};
  List<String> suitesOf(String package) => sources.putIfAbsent(package, () {
    return [
      for (final p in paths)
        if (_isSuiteOf(package, p) && File('$top/$p').existsSync())
          File('$top/$p').readAsStringSync(),
    ];
  });

  var screens = 0;
  final seen = <String>{};
  final uncovered = <Uncovered>[];
  final exempt = <String, String>{};

  for (final path in paths) {
    final package = _packageOf(path);
    // Listed by --cached but deleted from the working tree.
    if (package == null || !File('$top/$path').existsSync()) continue;
    screens++;
    seen.add(path);
    final basename = path.substring(path.lastIndexOf('/') + 1);

    final reason = deferred[path];
    if (reason != null) {
      exempt[path] = reason;
      continue;
    }

    final name = classNameOf(basename);
    final word = RegExp('\\b$name\\b');
    final audited = suitesOf(package)
        .any((src) => src.contains(_groupLiteral) && word.hasMatch(src));
    if (!audited) uncovered.add(Uncovered(path, name));
  }

  return AuditResult(
    screens: screens,
    uncovered: uncovered,
    exempt: exempt,
    stale: [
      for (final key in deferred.keys)
        if (!seen.contains(key)) key,
    ],
  );
}

/// Fixture tests for [checkAudit].
///
/// This gate's failure mode is a silent pass, which a clean workspace
/// cannot show: the real tree holds nothing the pattern must catch once
/// every screen is audited. So the shapes it must catch, and the ones it
/// must leave alone, are pinned here against a temporary tree. Run by the
/// `test-files` CI job.
void _selfTest() {
  var failures = 0;

  void expect(String name, bool condition, [String detail = '']) {
    if (condition) {
      stdout.writeln('  ok   $name');
    } else {
      failures++;
      stdout.writeln('  FAIL $name${detail.isEmpty ? '' : ': $detail'}');
    }
  }

  expect(
    'names a one-word screen',
    classNameOf('home_screen.dart') == 'HomeScreen',
  );
  expect(
    'names a multi-word screen',
    classNameOf('server_add_screen.dart') == 'ServerAddScreen',
  );

  final root = Directory.systemTemp.createTempSync('a11y_audit_');
  try {
    final paths = <String>[];
    void write(String path, String source) {
      final file = File('${root.path}/$path')..createSync(recursive: true);
      file.writeAsStringSync(source);
      paths.add(path);
    }

    const screen = 'class {C} extends StatelessWidget {}\n';
    String auditTest(String cls) =>
        "void main() {\n  group('accessibility audit', () {\n"
        '    testWidgets(\'x\', (t) async { await pump($cls()); });\n  });\n}\n';

    // Covered: audit group and class name in a test in the same package.
    write(
      'packages/a/lib/src/covered_screen.dart',
      screen.replaceAll('{C}', 'CoveredScreen'),
    );
    write(
      'packages/a/test/covered_screen_test.dart',
      auditTest('CoveredScreen'),
    );
    // Uncovered: nothing names it.
    write(
      'packages/a/lib/src/lonely_screen.dart',
      screen.replaceAll('{C}', 'LonelyScreen'),
    );
    // Exempt.
    write(
      'packages/a/lib/src/waiting_screen.dart',
      screen.replaceAll('{C}', 'WaitingScreen'),
    );
    // Not under a screens/ folder: any lib/** counts.
    write(
      'packages/b/lib/src/widgets/deep_screen.dart',
      screen.replaceAll('{C}', 'DeepScreen'),
    );
    // Audited in another package's tests only: does not count.
    write(
      'packages/b/lib/src/other_screen.dart',
      screen.replaceAll('{C}', 'OtherScreen'),
    );
    write('packages/a/test/other_screen_test.dart', auditTest('OtherScreen'));
    // Group present but names a different class.
    write(
      'packages/c/lib/src/mine_screen.dart',
      screen.replaceAll('{C}', 'MineScreen'),
    );
    write('packages/c/test/mine_screen_test.dart', auditTest('SomethingElse'));
    // Class named but no audit group.
    write(
      'packages/d/lib/src/plain_screen.dart',
      screen.replaceAll('{C}', 'PlainScreen'),
    );
    write(
      'packages/d/test/plain_screen_test.dart',
      "void main() { group('PlainScreen', () {}); }\n",
    );
    // Longer class name does not satisfy a shorter one.
    write(
      'packages/e/lib/src/home_screen.dart',
      screen.replaceAll('{C}', 'HomeScreen'),
    );
    write('packages/e/test/home_test.dart', auditTest('HomeScreenView'));
    // Support code, not a *_test.dart: ignored.
    write(
      'packages/f/lib/src/helper_screen.dart',
      screen.replaceAll('{C}', 'HelperScreen'),
    );
    write('packages/f/test/support/helper.dart', auditTest('HelperScreen'));
    // Not screens: other lib files, and a screen-named file outside lib.
    write('packages/a/lib/src/screen_helper.dart', 'class ScreenHelper {}\n');
    write('packages/a/test/fake_screen.dart', 'class FakeScreen {}\n');
    // Listed by git but deleted from disk: skipped.
    paths.add('packages/a/lib/src/gone_screen.dart');
    // Same name as an exempt screen, in another package: not exempt.
    write(
      'packages/g/lib/src/waiting_screen.dart',
      screen.replaceAll('{C}', 'WaitingScreen'),
    );

    final result = checkAudit(root.path, paths, {
      'packages/a/lib/src/waiting_screen.dart': '#1 in flight',
    });
    final listed = result.uncovered.map((u) => u.path).toSet();

    expect(
      'passes a covered screen',
      !listed.contains('packages/a/lib/src/covered_screen.dart'),
    );
    expect(
      'flags an uncovered screen',
      listed.contains('packages/a/lib/src/lonely_screen.dart'),
    );
    expect(
      'passes an exempt screen',
      !listed.contains('packages/a/lib/src/waiting_screen.dart'),
    );
    expect(
      'reports the exemption with its reason',
      result.exempt['packages/a/lib/src/waiting_screen.dart'] == '#1 in flight',
    );
    expect(
      "doesn't exempt a same-named screen in another package",
      listed.contains('packages/g/lib/src/waiting_screen.dart') &&
          result.exempt.length == 1,
    );
    expect(
      'flags a screen outside screens/',
      listed.contains('packages/b/lib/src/widgets/deep_screen.dart'),
    );
    expect(
      'ignores another package\'s tests',
      listed.contains('packages/b/lib/src/other_screen.dart'),
    );
    expect(
      'flags a group naming another class',
      listed.contains('packages/c/lib/src/mine_screen.dart'),
    );
    expect(
      'flags a class with no audit group',
      listed.contains('packages/d/lib/src/plain_screen.dart'),
    );
    expect(
      'matches the class as a whole word',
      listed.contains('packages/e/lib/src/home_screen.dart'),
    );
    expect(
      'ignores a non-suite under test/',
      listed.contains('packages/f/lib/src/helper_screen.dart'),
    );
    expect(
      'does not count non-screens or deleted files',
      result.screens == 10 && listed.length == 8,
      'screens=${result.screens} uncovered=${listed.length}',
    );
    expect(
      'names the class in the report',
      result.uncovered.any((u) => u.className == 'LonelyScreen'),
    );
    expect('is not ok with uncovered screens', !result.ok);
    expect('has no stale entry when all match', result.stale.isEmpty);

    final stale = checkAudit(root.path, paths, {
      'packages/a/lib/src/waiting_screen.dart': '#1 in flight',
      'packages/a/lib/src/renamed_screen.dart': '#2 in flight',
      // The basename alone, as the map was once keyed: matches nothing.
      'waiting_screen.dart': '#3 in flight',
    });
    expect(
      'flags a stale exemption',
      stale.stale.length == 2 &&
          stale.stale.contains('packages/a/lib/src/renamed_screen.dart') &&
          stale.stale.contains('waiting_screen.dart'),
      'stale=${stale.stale}',
    );

    final clean = checkAudit(root.path, [
      'packages/a/lib/src/covered_screen.dart',
      'packages/a/test/covered_screen_test.dart',
    ], const {});
    expect(
      'is ok when every screen is covered',
      clean.ok && clean.uncovered.isEmpty && clean.screens == 1,
    );
  } finally {
    root.deleteSync(recursive: true);
  }

  if (failures > 0) {
    stderr.writeln('\n$failures self-test failure(s).');
    exit(1);
  }
  stdout.writeln('check_a11y_audit self-test passed.');
}
