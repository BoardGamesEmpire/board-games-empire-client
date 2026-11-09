// Says whether a commit is a release, from the remote's tags (#419).
//
// `publish-web` must know whether the commit it builds is a release, to write
// the X.Y.Z image tag, and `github-release` needs the tag before this one, to
// start its notes there. Both read the remote's `v*` tags. An annotated tag
// needs peeling: `git ls-remote` lists the tag object's own SHA, and the
// commit it points at comes on a second, `^{}`, line.
//
// Usage, from the workspace root:
//   git ls-remote --tags <repo-url> 'refs/tags/v*' \
//     | dart run tool/release_tags.dart --commit <sha>
//   dart run tool/release_tags.dart --self-test   # the fixtures, no git
//
// Prints exactly two lines, in the form `$GITHUB_OUTPUT` takes:
//   tag=<vX.Y.Z, or empty>       the release tag the commit carries
//   previous=<vA.B.C, or empty>  the highest release tag below the root
//                                pubspec's version
//
// Exits 1, with a message on stderr and nothing on stdout, when the commit
// carries a `v` tag other than the root pubspec's `v<X.Y.Z>`, or more than
// one, or when the pubspec has no version to compare with. Exits 64 on bad
// arguments, among them an empty `--commit` value or one that starts with `-`.

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

const _commitFlag = '--commit';

const _selfTestFlag = '--self-test';

const _usage =
    'Usage: git ls-remote --tags <repo-url> \'refs/tags/v*\' '
    '| dart run tool/release_tags.dart $_commitFlag <sha> | $_selfTestFlag';

Future<void> main(List<String> args) async {
  final unknown = <String>[];
  String? commit;
  var selfTest = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == _commitFlag) {
      if (i + 1 >= args.length) {
        stderr.writeln('$_commitFlag needs a value.');
        stderr.writeln(_usage);
        exit(64); // EX_USAGE
      }
      commit = args[++i];
      // An unset `GITHUB_SHA` reaches here as "", and a forgotten value as the
      // next flag. Either would match no tag and print `tag=` with exit 0, a
      // green "not a release" for a commit nobody named.
      if (commit.isEmpty || commit.startsWith('-')) {
        stderr.writeln('$_commitFlag needs a commit SHA, got "$commit".');
        stderr.writeln(_usage);
        exit(64); // EX_USAGE
      }
    } else if (a == _selfTestFlag) {
      selfTest = true;
    } else {
      unknown.add(a);
    }
  }
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln(_usage);
    exit(64); // EX_USAGE
  }
  if (selfTest == (commit != null)) {
    stderr.writeln('Give either $_commitFlag <sha> or $_selfTestFlag.');
    stderr.writeln(_usage);
    exit(64); // EX_USAGE
  }

  if (selfTest) {
    _selfTest();
    return;
  }

  final String version;
  try {
    version = _rootVersion();
  } on ReleaseTagException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }

  final lsRemote = await utf8.decoder.bind(stdin).join();
  final ({String? tag, String? previous}) release;
  try {
    release = releaseFor(
      tags: parseTagCommits(lsRemote),
      commit: commit!,
      version: version,
    );
  } on ReleaseTagException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  stdout.writeln('tag=${release.tag ?? ''}');
  stdout.writeln('previous=${release.previous ?? ''}');
}

/// A tag the release flow counts: `v` and a major.minor.patch. `vnext` and
/// `v1.2` are someone's own tags, and neither is a release.
final _releaseTag = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$');

final _version = RegExp(r'^(\d+\.\d+\.\d+)\+\d+$');

/// A failure the caller should see as a message, not a stack trace: the
/// remote's tags and the root pubspec disagree, or there is no version to
/// compare against.
final class ReleaseTagException implements Exception {
  ReleaseTagException(this.message);

  final String message;

  @override
  String toString() => 'ReleaseTagException: $message';
}

/// Maps each tag in `git ls-remote --tags` output to the commit it names.
///
/// An annotated tag is listed twice: `refs/tags/<t>` with the tag object's
/// SHA, and `refs/tags/<t>^{}` with the commit's. The peeled line wins,
/// whichever comes first, since the commit is what CI is asked about. Lines
/// that are not `<sha>\trefs/tags/<name>` are skipped.
Map<String, String> parseTagCommits(String lsRemote) {
  final line = RegExp(r'^(\S+)\trefs/tags/(\S+?)(\^\{\})?$');
  final commits = <String, String>{};
  final peeled = <String>{};
  for (final raw in const LineSplitter().convert(lsRemote)) {
    final m = line.firstMatch(raw);
    if (m == null) continue;
    final name = m.group(2)!;
    if (m.group(3) != null) {
      commits[name] = m.group(1)!;
      peeled.add(name);
    } else if (!peeled.contains(name)) {
      commits[name] = m.group(1)!;
    }
  }
  return commits;
}

/// The release tag [commit] carries, and the highest release tag below
/// [version], given [tags] as [parseTagCommits] reads them.
///
/// Throws a [ReleaseTagException] when [commit] carries more than one release
/// tag, or one that is not `v$version`: the tag and the pubspec both claim to
/// say what this release is, and a build must not guess which is right.
({String? tag, String? previous}) releaseFor({
  required Map<String, String> tags,
  required String commit,
  required String version,
}) {
  final target = _parts(version);
  if (target == null) {
    throw ReleaseTagException('Version "$version" is not major.minor.patch.');
  }

  final release = [
    for (final name in tags.keys)
      if (_releaseTag.hasMatch(name)) name,
  ];

  final onCommit = [
    for (final name in release)
      if (tags[name] == commit) name,
  ];
  if (onCommit.length > 1) {
    throw ReleaseTagException(
      'Commit $commit carries more than one release tag: '
      '${onCommit.join(', ')}.',
    );
  }
  final tag = onCommit.isEmpty ? null : onCommit.single;
  if (tag != null && tag != 'v$version') {
    throw ReleaseTagException(
      'Commit $commit is tagged $tag, but the root pubspec.yaml says '
      '$version, so the release would be v$version.',
    );
  }

  String? previous;
  List<int>? previousParts;
  for (final name in release) {
    final parts = _parts(name.substring(1))!;
    if (_compare(parts, target) >= 0) continue;
    if (previousParts == null || _compare(parts, previousParts) > 0) {
      previous = name;
      previousParts = parts;
    }
  }
  return (tag: tag, previous: previous);
}

/// The numbers of a `major.minor.patch` string, or null. Compared as numbers:
/// as text, 0.10.0 would sort below 0.9.0.
List<int>? _parts(String version) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(version);
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

/// The root pubspec's `major.minor.patch`, without its build number.
///
/// Parsed as YAML, as tool/check_sdk_constraints.dart reads it, so a value
/// the constraints check accepts, quoted or not, is one this reads too.
String _rootVersion() => _versionOf(
  File('${_workspaceRoot().path}/pubspec.yaml').readAsStringSync(),
);

String _versionOf(String pubspec) {
  final Object? yaml;
  try {
    yaml = loadYaml(pubspec);
  } on YamlException catch (e) {
    throw ReleaseTagException('The root pubspec.yaml is not valid YAML: $e');
  }
  final value = yaml is YamlMap ? yaml['version']?.toString() : null;
  final m = value == null ? null : _version.firstMatch(value);
  if (m == null) {
    throw ReleaseTagException(
      'The root pubspec.yaml has no top-level `version:` in the form '
      'major.minor.patch+build.',
    );
  }
  return m.group(1)!;
}

/// The workspace root, identified by reading its pubspec rather than by
/// assuming the working directory, as tool/build_android.dart does.
Directory _workspaceRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('\nworkspace:')) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw ReleaseTagException(
    'Could not locate the workspace root from ${Directory.current.path}. '
    'Run this from the repository.',
  );
}

void _selfTest() {
  var failures = 0;

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

  void expectReleaseTagException(
    String name,
    void Function() body,
    List<String> messageHas,
  ) {
    try {
      body();
      failures++;
      stdout.writeln('  FAIL $name: no ReleaseTagException');
    } on ReleaseTagException catch (e) {
      final missing = [
        for (final part in messageHas)
          if (!e.message.contains(part)) part,
      ];
      if (missing.isEmpty) {
        stdout.writeln('  ok   $name');
      } else {
        failures++;
        stdout.writeln('  FAIL $name');
        stdout.writeln('       message lacks: ${jsonEncode(missing)}');
        stdout.writeln('       message:       ${jsonEncode(e.message)}');
      }
    }
  }

  Object? release(Map<String, String> tags, String commit, String version) {
    final r = releaseFor(tags: tags, commit: commit, version: version);
    return {'tag': r.tag, 'previous': r.previous};
  }

  const lightweight =
      'a1\trefs/tags/v0.1.0\n'
      'a9\trefs/tags/v0.9.0\n'
      'b0\trefs/tags/v0.10.0\n'
      'c2\trefs/tags/v0.2.0\n';
  final lightweightTags = parseTagCommits(lightweight);

  expect('parse: tag name to commit', lightweightTags, {
    'v0.1.0': 'a1',
    'v0.9.0': 'a9',
    'v0.10.0': 'b0',
    'v0.2.0': 'c2',
  });
  expect(
    'parse: a peeled line overrides the tag object, in either order',
    [
      parseTagCommits('t1\trefs/tags/v0.1.0\nc1\trefs/tags/v0.1.0^{}\n'),
      parseTagCommits('c1\trefs/tags/v0.1.0^{}\nt1\trefs/tags/v0.1.0\n'),
    ],
    [
      {'v0.1.0': 'c1'},
      {'v0.1.0': 'c1'},
    ],
  );
  expect(
    'parse: skips lines that are not <sha>\\trefs/tags/<name>',
    parseTagCommits(
      '\nwarning: noise\na1\trefs/heads/main\na1 refs/tags/v0.1.0\n',
    ),
    <String, String>{},
  );
  expect(
    'parse: tolerates CRLF line endings',
    parseTagCommits('a1\trefs/tags/v0.1.0\r\n'),
    {'v0.1.0': 'a1'},
  );

  expect(
    'release: lightweight tag, previous by number not by text',
    release(lightweightTags, 'c2', '0.2.0'),
    {'tag': 'v0.2.0', 'previous': 'v0.1.0'},
  );
  expect(
    'release: annotated tag, peeled to its commit',
    release(
      parseTagCommits('t1\trefs/tags/v0.1.0\nc1\trefs/tags/v0.1.0^{}\n'),
      'c1',
      '0.1.0',
    ),
    {'tag': 'v0.1.0', 'previous': null},
  );
  expect(
    'release: no tag on the commit',
    release(lightweightTags, 'zz', '0.2.0'),
    {'tag': null, 'previous': 'v0.1.0'},
  );
  expectReleaseTagException(
    'release: a tag that disagrees with the version',
    () => release(lightweightTags, 'c2', '0.3.0'),
    ['v0.2.0', '0.3.0'],
  );
  expectReleaseTagException(
    'release: two tags on one commit',
    () => release(
      parseTagCommits('c2\trefs/tags/v0.2.0\nc2\trefs/tags/v0.2.1\n'),
      'c2',
      '0.2.0',
    ),
    ['v0.2.0', 'v0.2.1'],
  );
  expect(
    'release: tags that are not releases are ignored',
    release(
      parseTagCommits('c2\trefs/tags/vnext\nc2\trefs/tags/v1.2\n'),
      'c2',
      '0.2.0',
    ),
    {'tag': null, 'previous': null},
  );
  expect(
    'release: previous never reaches the version itself or above',
    release(
      parseTagCommits('a1\trefs/tags/v0.2.0\nb1\trefs/tags/v0.2.1\n'),
      'zz',
      '0.2.0',
    ),
    {'tag': null, 'previous': null},
  );

  expect(
    'version: drops the build number',
    _versionOf('name: bge\nversion: 0.2.0+14\nenvironment:\n'),
    '0.2.0',
  );
  expectReleaseTagException(
    'version: refuses one with no build number',
    () => _versionOf('name: bge\nversion: 0.2.0\n'),
    ['version'],
  );
  expect(
    'version: reads a quoted value',
    _versionOf("name: bge\nversion: '0.2.0+14' # quoted\n"),
    '0.2.0',
  );
  expectReleaseTagException(
    'version: ignores an indented version: line',
    () => _versionOf('name: bge\ndependencies:\n  version: 1.2.3+4\n'),
    ['version'],
  );

  if (failures > 0) {
    stderr.writeln('\n$failures self-test failure(s).');
    exit(1);
  }
  stdout.writeln('release_tags self-test passed.');
}
