// Builds the web app the way #418 publishes it, for both
// `melos run build-web` and CI's `build-web` job. One definition, so a
// local production build is the published one.
//
// Usage, from the workspace root, once the drift runtime files are
// fetched (`melos run build-web` fetches them first):
//   dart run tool/build_web.dart
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
  if (args.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${args.join(', ')}');
    stderr.writeln('Usage: dart run tool/build_web.dart');
    exit(64); // EX_USAGE
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
