// Builds the web app the way #418 publishes it, for both
// `melos run build-web` and CI's `build-web` job. One definition, so a
// local production build is the published one.
//
// Usage, from the workspace root, once the drift runtime files are
// fetched (`melos run build-web` fetches them first):
//   dart run tool/build_web.dart
//   dart run tool/build_web.dart --self-test   # step 5's fixtures, no build
//
// ── What it does ────────────────────────────────────────────────────
//
//   1. Empties apps/browser/build/web. `flutter build web` keeps whatever
//      earlier builds left in its output, so without this a local build
//      can ship files the current one did not produce. A CI checkout
//      starts empty; this makes every build start the same way.
//   2. Builds with the published flags. JS only: no browser suite runs a
//      wasm build yet (#420). `--no-web-resources-cdn` serves the renderer
//      from the app's own origin rather than Google's CDN, so a
//      self-hosted instance does not depend on gstatic.com to draw a
//      frame.
//   3. Removes the two tooling dotfiles, which are not app files. Any
//      other dotfile fails the build rather than shipping unnoticed.
//   4. Fails unless every file the app boots from is present and
//      non-empty, the renderer and its fallback font included.
//   5. Sorts the `wasmHashes` map in flutter_bootstrap.js. flutter_tools
//      writes it in the order the filesystem lists the CanvasKit files,
//      which differs between machines: CI's build of 28a49e6 and a macOS
//      build differed in that order and nothing else. The loader only
//      looks keys up in it, so the order changes nothing at runtime, and
//      sorting it lets builds of one commit hold the same files, which
//      CI's `publish-web` relies on to leave `edge` alone (#424). A map in
//      a shape this cannot read fails the build rather than going
//      unsorted.

import 'dart:convert';
import 'dart:io';

const _app = 'apps/browser';

const _flags = <String>['build', 'web', '--release', '--no-web-resources-cdn'];

/// Files tooling writes into the output, which are not part of the app.
const _tooling = <String>[
  // flutter_tools' build stamp.
  '.last_build_id',
  // tool/fetch_web_assets.dart's stamp, copied over from web/.
  '.drift-web-assets',
];

/// The files the app cannot boot without, from this origin.
const _required = <String>[
  'index.html',
  // index.html loads it, and it carries the loader and the build config.
  'flutter_bootstrap.js',
  'main.dart.js',
  // `--no-web-resources-cdn` is why these are served from here. The loader
  // picks a CanvasKit variant per browser: chromium/ where the browser has
  // Chromium's break iterators and image codecs, the full build elsewhere.
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
  'assets/fonts/fallback/Roboto-Regular.ttf',
  'sqlite3.wasm',
  'drift_worker.js',
];

Future<void> main(List<String> args) async {
  final unknown = args.where((a) => a != '--self-test');
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln('Usage: dart run tool/build_web.dart [--self-test]');
    exit(64); // EX_USAGE
  }

  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }

  final app = Directory('${_workspaceRoot().path}/$_app');
  final output = Directory('${app.path}/build/web');
  if (output.existsSync()) output.deleteSync(recursive: true);

  final flutter = await Process.start(
    'flutter',
    _flags,
    workingDirectory: app.path,
    mode: ProcessStartMode.inheritStdio,
    // `flutter` is a batch file on Windows, which needs a shell to start.
    runInShell: Platform.isWindows,
  );
  final code = await flutter.exitCode;
  if (code != 0) {
    stderr.writeln('flutter ${_flags.join(' ')} failed with exit code $code.');
    exit(code);
  }

  for (final name in _tooling) {
    final file = File('${output.path}/$name');
    if (file.existsSync()) file.deleteSync();
  }

  final entities = output.listSync(recursive: true);
  final stray = [
    for (final entity in entities)
      if (_name(entity).startsWith('.')) _relative(entity, output),
  ]..sort();
  if (stray.isNotEmpty) {
    stderr.writeln(
      'The web build holds dotfiles the image would ship: '
      '${stray.join(', ')}. Stop them reaching $_app/web, or, if a '
      'tool writes them, list them in tool/build_web.dart.',
    );
    exit(1);
  }

  final missing = [
    for (final name in _required)
      if (!_hasContent(File('${output.path}/$name'))) name,
  ];
  if (missing.isNotEmpty) {
    stderr.writeln(
      'The web build has no ${missing.join(', ')}. The drift runtime files '
      'come from `dart run tool/fetch_web_assets.dart`, and the rest from '
      '`flutter ${_flags.join(' ')}` itself.',
    );
    exit(1);
  }

  final bootstrap = File('${output.path}/flutter_bootstrap.js');
  final source = bootstrap.readAsStringSync();
  final sorted = _sortWasmHashes(source);
  if (sorted == null) {
    stderr.writeln(
      'flutter_bootstrap.js has a "wasmHashes" map this script cannot read, '
      'so it would stay in directory order. Teach _sortWasmHashes in '
      'tool/build_web.dart the new shape.',
    );
    exit(1);
  }
  if (sorted != source) bootstrap.writeAsStringSync(sorted);

  final files = entities.whereType<File>().length;
  stdout.writeln('$_app/build/web: $files files, ready to ship.');
}

/// The workspace root, identified by reading its pubspec rather than by
/// assuming the working directory, as tool/fetch_web_assets.dart does.
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
  stderr.writeln(
    'Could not locate the workspace root from ${Directory.current.path}. '
    'Run this from the repository.',
  );
  exit(1);
}

/// The last segment of [entity]'s path, for directories as well as files.
String _name(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty);

String _relative(FileSystemEntity entity, Directory root) =>
    entity.path.substring(root.path.length + 1);

bool _hasContent(File file) => file.existsSync() && file.lengthSync() > 0;

/// The `"wasmHashes"` key in flutter_bootstrap.js's build config.
const _wasmHashesKey = '"wasmHashes":';

/// That key and the flat JSON object flutter_tools writes after it.
final _wasmHashes = RegExp(
  '$_wasmHashesKey'
  r'(\{[^{}]*\})',
);

/// [source] with the keys of its `"wasmHashes"` map sorted, or null when
/// the map is not the flat JSON object of strings this expects.
String? _sortWasmHashes(String source) {
  final matches = _wasmHashes.allMatches(source).length;
  if (matches != _wasmHashesKey.allMatches(source).length) return null;
  var readable = true;
  final sorted = source.replaceAllMapped(_wasmHashes, (match) {
    final hashes = _stringMap(match[1]!);
    if (hashes == null) {
      readable = false;
      return match[0]!;
    }
    final keys = hashes.keys.toList()..sort();
    return '$_wasmHashesKey${jsonEncode({for (final k in keys) k: hashes[k]})}';
  });
  return readable ? sorted : null;
}

/// [json] as a map of strings to strings, or null when it is not one.
Map<String, String>? _stringMap(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  if (decoded.values.any((value) => value is! String)) return null;
  return decoded.cast<String, String>();
}

/// Fixture tests for [_sortWasmHashes].
///
/// Its failure mode is a silent pass: a pattern that stops matching leaves
/// the map in directory order, and builds of one commit differ again with
/// nothing to show why. So the shapes it must sort, and the ones it must
/// refuse, are pinned here. Run by CI's `build-web` job.
void _selfTest() {
  var failures = 0;

  void expect(String name, String? actual, String? expected) {
    if (actual == expected) {
      stdout.writeln('  ok   $name');
    } else {
      failures++;
      stdout.writeln('  FAIL $name:\n    got  $actual\n    want $expected');
    }
  }

  // The shape flutter_tools writes, with the loader's own lookup after it.
  String bootstrap(String hashes) =>
      '_flutter.buildConfig = {"engineRevision":"5d53",'
      '"wasmHashes":$hashes,"builds":[{"compileTarget":"dart2js"}]};\n'
      'var b=(n,e)=>{let s=window._flutter?.buildConfig?.wasmHashes};\n';

  // The orders CI's build and a macOS build of 28a49e6 wrote.
  const ci =
      '{"wimp.wasm":"74","chromium/canvaskit.wasm":"ba",'
      '"webparagraph/canvaskit.wasm":"7a","canvaskit.wasm":"28",'
      '"skwasm.wasm":"a9","skwasm_heavy.wasm":"78"}';
  const macos =
      '{"wimp.wasm":"74","webparagraph/canvaskit.wasm":"7a",'
      '"skwasm.wasm":"a9","chromium/canvaskit.wasm":"ba",'
      '"canvaskit.wasm":"28","skwasm_heavy.wasm":"78"}';
  const sorted =
      '{"canvaskit.wasm":"28","chromium/canvaskit.wasm":"ba",'
      '"skwasm.wasm":"a9","skwasm_heavy.wasm":"78",'
      '"webparagraph/canvaskit.wasm":"7a","wimp.wasm":"74"}';

  expect(
    'sorts the order CI wrote',
    _sortWasmHashes(bootstrap(ci)),
    bootstrap(sorted),
  );
  expect(
    'sorts the order macOS wrote',
    _sortWasmHashes(bootstrap(macos)),
    bootstrap(sorted),
  );
  expect(
    'keeps a sorted map',
    _sortWasmHashes(bootstrap(sorted)),
    bootstrap(sorted),
  );
  expect(
    'keeps an empty map',
    _sortWasmHashes(bootstrap('{}')),
    bootstrap('{}'),
  );
  expect('keeps a file with no map', _sortWasmHashes('var a=1;'), 'var a=1;');
  expect(
    'refuses a map with spaces',
    _sortWasmHashes(bootstrap(' $sorted')),
    null,
  );
  expect(
    'refuses a nested map',
    _sortWasmHashes(bootstrap('{"a.wasm":{"b":"c"}}')),
    null,
  );
  expect(
    'refuses a value that is not a string',
    _sortWasmHashes(bootstrap('{"a.wasm":1}')),
    null,
  );
  expect(
    'refuses a map that is not JSON',
    _sortWasmHashes(bootstrap("{'a.wasm':'1'}")),
    null,
  );

  if (failures > 0) {
    stderr.writeln('\n$failures self-test failure(s).');
    exit(1);
  }
  stdout.writeln('build_web self-test passed.');
}
