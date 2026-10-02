// Fetches the two binary assets drift/wasm needs at runtime (#288):
//
//   * `sqlite3.wasm`     — the sqlite3 build the database runs on
//   * `drift_worker.js`  — the worker drift hosts the database in
//
// Neither is committed. They are versioned artifacts of the `drift`
// package, and a committed copy drifts against the pubspec in silence:
// nothing in the tree would notice that the checked-in worker predates
// the drift version actually resolved. Fetching them keeps the two in
// lockstep by construction.
//
// ── Where the version comes from ────────────────────────────────────
//
// Drift's docs say to take both files from the SAME release as the
// package, so the release tag is DERIVED from the resolved `drift`
// version in `pubspec.lock` — `drift 2.34.3` fetches from
// `drift-2.34.3`. Bumping `drift` moves the assets with it.
//
// This requires drift >= 2.34.2, the first release publishing
// `sqlite3.wasm` as an asset (earlier ones ship only the worker). Keep
// the workspace floor at or above that so an older resolve cannot 404
// here.
//
// ── Why each download is checked against a committed SHA-256 ─────────
//
// These files ship in the web image every backend deployment serves
// (#418), and a release asset can be replaced after it is published. So
// `_checksums` below holds each file's digest per release, and a download
// that does not match is discarded before it reaches `web/`. The cost is
// one step per drift bump: add the new release's digests, or the fetch
// fails and names the release. That keeps the reason for not committing
// the files, too: a committed copy goes stale in silence, while a stale
// checksum fails loudly.
//
// ── Why the plain build and not sqlite3mc.wasm ──────────────────────
//
// Drift also publishes `sqlite3mc.wasm`, the SQLite3MultipleCiphers
// build that provides encryption at rest — the same cipher the native
// executor uses (#16). Web deliberately does NOT use it: per #63, the
// browser origin sandbox is the security boundary, and any key the page
// can read, page-injected JavaScript can read too. Fetching the plain
// build is that decision, expressed where the artifact is chosen.
//
// Usage:
//   dart run tool/fetch_web_assets.dart           # fetch what is missing or stale
//   dart run tool/fetch_web_assets.dart --check    # verify only, exit 1 if not ready
//   dart run tool/fetch_web_assets.dart --force    # re-download even if current
//
// Run from the workspace root (melos: `melos run web:assets`).

import 'dart:io';

import 'package:crypto/crypto.dart';

/// Files to fetch from the drift release.
const _assets = <String>['sqlite3.wasm', 'drift_worker.js'];

/// The SHA-256 of every asset, for the drift release the lock resolves.
///
/// After a drift bump, replace the entry with the new release's digests.
/// GitHub lists each asset's digest on the release page
/// (https://github.com/simolus3/drift/releases/tag/drift-<version>).
const _checksums = <String, Map<String, String>>{
  'drift-2.34.3': {
    'sqlite3.wasm':
        '41cf968998241465d8b1dfffb1eb60dd10c35de5022a3647e14174ea3af84143',
    'drift_worker.js':
        '4db0469de8ceabad8d5cd3d920614486ba587e100e39523f36f704a3aec5f26c',
  },
};

/// Every directory the assets are placed in, relative to the workspace root.
///
/// Two consumers, not one:
///
///   * `apps/browser/web/` — served beside the app by `flutter run`/`build
///     web`, which is where the browser fetches them at runtime.
///   * `packages/storage/web_storage/test/` — `flutter test --platform
///     chrome` serves the package under test, and a browser suite resolves
///     these URIs relative to its own location, so the files must sit
///     beside the test that loads them.
///   * `packages/platform/web/test/` — same reason, for the #137 user-session
///     acceptance suite, which drives the real repositories over a real wasm
///     database. Every package with a browser suite that opens a database
///     needs its own copy; there is no shared serving root.
const _destinations = <String>[
  'apps/browser/web',
  'packages/storage/web_storage/test',
  'packages/platform/web/test',
];

/// Records which release the files in a destination came from. It is
/// written only once every file in the destination has passed its checksum.
/// A stamp alone never makes a destination current: the files are hashed on
/// every run, so one fetched before the checksums existed, or changed since,
/// is fetched again.
const _stampFile = '.drift-web-assets';

const _baseUrl = 'https://github.com/simolus3/drift/releases/download';

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final force = args.contains('--force');
  final unknown = args.where((a) => a != '--check' && a != '--force');
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln(
      'Usage: dart run tool/fetch_web_assets.dart [--check] [--force]',
    );
    exit(64); // EX_USAGE
  }
  if (check && force) {
    stderr.writeln('--check and --force are mutually exclusive.');
    exit(64);
  }

  final root = _workspaceRoot();
  final release = 'drift-${_resolvedDriftVersion(root)}';
  final digests = _checksums[release];
  if (digests == null || !_assets.every(digests.containsKey)) {
    stderr.writeln(
      'tool/fetch_web_assets.dart has no SHA-256 for every asset of '
      '$release. Add the digests GitHub lists for ${_assets.join(' and ')} '
      'on https://github.com/simolus3/drift/releases/tag/$release.',
    );
    exit(1);
  }

  var missing = false;
  for (final destination in _destinations) {
    final dir = Directory('${root.path}/$destination');

    if (_isCurrent(dir, release, digests) && !force) {
      stdout.writeln('$destination: up to date ($release)');
      continue;
    }
    if (check) {
      stderr.writeln(
        '$destination: assets missing, from a different release, or not '
        'matching their checksums (expected $release).',
      );
      missing = true;
      continue;
    }

    await dir.create(recursive: true);
    for (final asset in _assets) {
      final target = File('${dir.path}/$asset');
      stdout.writeln('$destination: fetching $asset from $release');
      await _download('$_baseUrl/$release/$asset', target, digests[asset]!);
    }
    File('${dir.path}/$_stampFile').writeAsStringSync('$release\n');
  }

  if (check && missing) {
    stderr.writeln('');
    stderr.writeln('Run `melos run web:assets` to fetch them.');
    exit(1);
  }
}

/// The workspace root, identified by reading its pubspec rather than by
/// assuming the working directory — the same rule the boundary and
/// design-system tests follow.
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

/// Reads the resolved `drift` version out of `pubspec.lock`.
///
/// The lock, not the pubspec constraint: what matters is the version the
/// app is actually built against, and a caret constraint does not name one.
///
/// Hand-parsed rather than via `package:yaml`: this needs one scalar from a
/// known shape.
String _resolvedDriftVersion(Directory root) {
  final lock = File('${root.path}/pubspec.lock');
  if (!lock.existsSync()) {
    stderr.writeln(
      'No pubspec.lock at ${lock.path}. Run `flutter pub get` first.',
    );
    exit(1);
  }

  final lines = lock.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] != '  drift:') continue;
    // Scan this package's block only: a two-space key ends it.
    for (var j = i + 1; j < lines.length; j++) {
      final line = lines[j];
      if (line.startsWith('  ') && !line.startsWith('   ')) break;
      final match = RegExp(r'^\s+version: "([^"]+)"$').firstMatch(line);
      if (match != null) return match.group(1)!;
    }
    break;
  }
  stderr.writeln('Could not find a resolved `drift` version in pubspec.lock.');
  exit(1);
}

/// Whether [dir] already holds every asset, stamped with [release], and
/// each one matches its SHA-256 in [digests].
bool _isCurrent(Directory dir, String release, Map<String, String> digests) {
  final stamp = File('${dir.path}/$_stampFile');
  if (!stamp.existsSync()) return false;
  if (stamp.readAsStringSync().trim() != release) return false;
  return _assets.every((a) {
    final file = File('${dir.path}/$a');
    return file.existsSync() && _sha256Of(file) == digests[a];
  });
}

/// The SHA-256 of [file], as lowercase hex.
///
/// It hashes the bytes on disk, the ones that ship, for a file just
/// downloaded and for one already in place alike. Both assets together are
/// about a megabyte, so reading one whole is cheap.
String _sha256Of(File file) =>
    sha256.convert(file.readAsBytesSync()).toString();

/// Downloads [url] to [target] via a staging file, so an interrupted
/// transfer cannot leave a truncated asset that looks present, and a file
/// whose SHA-256 is not [sha256Hex] never reaches [target] at all.
///
/// The staging file sits beside the target — the rename is then a
/// same-filesystem move — and is removed on every failure path. It has to
/// be: `flutter build web` copies whatever sits in `apps/browser/web/` into
/// the build output, so an abandoned `.part` would ship as dead weight.
Future<void> _download(String url, File target, String sha256Hex) async {
  final partial = File('${target.path}.part');

  // A run killed mid-transfer leaves one behind — `exit()` does not unwind
  // `finally`, and a signal runs nothing at all — so clear it on the way in
  // as well as on the way out.
  _discard(partial);

  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      _discard(partial);
      stderr.writeln('GET $url failed with HTTP ${response.statusCode}.');
      exit(1);
    }
    await response.pipe(partial.openWrite());
    final actual = _sha256Of(partial);
    if (actual != sha256Hex) {
      _discard(partial);
      stderr.writeln('$url does not match its committed checksum.');
      stderr.writeln('  expected sha256 $sha256Hex');
      stderr.writeln('  received sha256 $actual');
      stderr.writeln(
        'The release asset changed or the download was corrupted. Find out '
        'which before changing the checksum.',
      );
      exit(1);
    }
    partial.renameSync(target.path);
  } on SocketException catch (e) {
    _discard(partial);
    stderr.writeln('Could not reach $url: ${e.message}');
    exit(1);
  } on Object {
    // A read error or a short write mid-`pipe`: same cleanup, but the error
    // is not this function's to interpret.
    _discard(partial);
    rethrow;
  } finally {
    client.close();
  }
}

/// Deletes [file] if it is there, ignoring a failure to do so.
///
/// A staging file left behind is litter, not corruption — the target is only
/// ever renamed into place from a complete transfer — so failing the fetch
/// over an undeletable one would be the worse outcome.
void _discard(File file) {
  try {
    if (file.existsSync()) {
      file.deleteSync();
    }
  } on FileSystemException {
    // Intentionally ignored; see above.
  }
}
