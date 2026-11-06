// Runs the golden suites inside the golden-test container (#159).
//
// The committed `test/**/goldens/ci/` baselines are rendered by one host:
// tool/goldens/Dockerfile, the pinned Flutter on a pinned Ubuntu. macOS
// anti-aliases the edges of the same Ahem shapes differently, so a host
// `flutter test --tags golden` on a Mac fails by design. This script is
// the one way to compare or regenerate the baselines, and CI's `goldens`
// job runs it too, so a contributor's run and CI's are the same command.
//
// Usage, from the workspace root:
//   dart run tool/goldens.dart              # compare against the baselines
//   dart run tool/goldens.dart --update     # rewrite them after an intended change
//   dart run tool/goldens.dart --image-tag  # print the image tag; needs no Docker
//
// Exits 0 when every golden package passes, 1 on a failure or when Docker
// isn't running, and 64 on a usage error. Melos: `melos run test:goldens`
// and `melos run goldens:update`.
//
// ── The image ──────────────────────────────────────────────────────
//
// Tagged `bge-goldens:<hash>`, where the hash covers the Dockerfile, the
// install script and the Flutter digest, so a toolchain bump or an image
// change builds a new image and an unchanged one is reused. The first run
// builds it, which takes minutes (more under emulation on Apple silicon).
//
// ── Keeping the host checkout intact ───────────────────────────────
//
// The checkout is mounted read-only. The container copies it, leaving out
// `.git` and every `.dart_tool` and `build`, then resolves and tests the
// copy. It can't run against the host's files: `flutter pub get` in a
// workspace writes into every member, not only the root. It writes each
// member's `.dart_tool`, regenerates the apps' and plugins' platform files
// (`local.properties`, `Generated.xcconfig`, `.flutter-plugins-dependencies`)
// and the features' localizations, all with the container's paths in them
// and, on a Linux host, owned by root.
//
// Only the files under `test/goldens/` that the run created or changed
// come back: new baselines with `--update`, the diff images on a failure.
// The container writes them to `.dart_tool/goldens_out/` and hands that
// directory to the host user. This script then copies them into place,
// refusing anything outside a golden package's `test/goldens/`, and deletes
// it.
//
// Pub's downloads go to a named volume, so later runs skip them. When
// GOLDENS_PUB_CACHE names a directory, that is mounted as the pub cache
// instead. CI points it at the runner's pub cache, which setup-flutter
// has already restored and the host resolve has filled, so the container
// downloads nothing. Don't point it at your own pub cache on a Linux host:
// the container writes to it as root.

import 'dart:io';

import 'package:crypto/crypto.dart';

const _usage = 'Usage: dart run tool/goldens.dart [--update|--image-tag]';

/// The files the image is built from, hashed in this order for its tag.
const _imageInputs = [
  'tool/goldens/Dockerfile',
  'tool/install_flutter.sh',
  'tool/flutter_sdk.sha256',
];

/// Runs inside the container, with the checkout at /src (read-only) and
/// the hand-back directory at /out. `PACKAGES` and `UPDATE` come in
/// through the environment.
///
/// The CPU check comes first. Skia picks its raster code from the CPU's
/// features, so a CPU without AVX2 and FMA can anti-alias edges
/// differently from CI's runners, which all have both. Docker Desktop's
/// Rosetta emulation reports both; plain QEMU emulation may not.
///
/// `--no-pub` because the root resolve already covered every package;
/// without it each `flutter test` would resolve the workspace again.
/// Every package runs even after one fails, and the hand-back and chown
/// run either way, so a failure's images reach the host owned by the host
/// user and the run still exits non-zero.
const _containerScript = r'''
set -uo pipefail
if ! grep -qw avx2 /proc/cpuinfo || ! grep -qw fma /proc/cpuinfo; then
  echo "warning: this container's CPU reports no AVX2 or FMA. Skia may anti-alias differently here than on CI's runners, so these renders may not match CI's. On Apple silicon, turn on Docker Desktop's Rosetta emulation for x86_64." >&2
fi
mkdir -p /work
tar -C /src --exclude=./.git --exclude=.dart_tool --exclude=build -cf - . | tar -C /work -xf - || exit 1
cd /work
flutter pub get >/tmp/pub-get.log 2>&1 || { cat /tmp/pub-get.log; exit 1; }
rc=0
for p in $PACKAGES; do (cd "$p" && flutter test --no-pub --tags golden $UPDATE) || rc=1; done
for p in $PACKAGES; do
  while IFS= read -r -d '' f; do
    cmp -s "$f" "/src/$f" && continue
    { mkdir -p "/out/$(dirname "$f")" && cp "$f" "/out/$f"; } || rc=1
  done < <(find "$p/test/goldens" -type f -print0)
done
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID:$HOST_GID" /out; fi
exit $rc
''';

/// Where the container leaves the files it hands back, under the root
/// `.dart_tool` so it is gitignored and inside a directory Docker can
/// already mount.
const _handBackPath = '.dart_tool/goldens_out';

Future<void> main(List<String> args) async {
  final unknown = args.where((a) => a != '--update' && a != '--image-tag');
  if (unknown.isNotEmpty || args.length > 1) {
    stderr.writeln(
      unknown.isNotEmpty
          ? 'Unknown argument(s): ${unknown.join(', ')}'
          : 'Pass at most one of --update and --image-tag.',
    );
    stderr.writeln(_usage);
    exit(64); // EX_USAGE
  }

  if (!File(_imageInputs.first).existsSync()) {
    stderr.writeln(
      '${_imageInputs.first} not found. Run this from the workspace root.',
    );
    exit(1);
  }

  final image = 'bge-goldens:${_imageHash()}';
  if (args.contains('--image-tag')) {
    stdout.writeln(image);
    return;
  }

  if (!await _dockerRunning()) {
    stderr.writeln(
      'Golden tests run in a Linux container (#159) and need Docker '
      'running. Install Docker Desktop or the docker engine, start it, '
      'and re-run.',
    );
    exit(1);
  }

  final packages = await _goldenPackages();
  if (packages.isEmpty) {
    stderr.writeln('No package has tracked files under test/goldens/.');
    exit(1);
  }

  if (!await _imageExists(image)) {
    stdout.writeln('Building $image (first run; this takes minutes).');
    final built = await _stream('docker', [
      'build',
      '--platform',
      'linux/amd64',
      '-t',
      image,
      '-f',
      'tool/goldens/Dockerfile',
      'tool',
    ]);
    if (built != 0) {
      stderr.writeln('Building $image failed.');
      exit(1);
    }
  }

  // Emptied first, so only this run's files are handed back.
  final handBack = Directory(_handBackPath);
  if (handBack.existsSync()) handBack.deleteSync(recursive: true);
  handBack.createSync(recursive: true);

  final pubCache = Platform.environment['GOLDENS_PUB_CACHE'];
  final update = args.contains('--update');
  final owner = await _hostOwner();
  final code = await _stream('docker', [
    'run',
    '--rm',
    '--platform',
    'linux/amd64',
    '-v',
    '${Directory.current.path}:/src:ro',
    '-v',
    '${handBack.absolute.path}:/out',
    '-v',
    pubCache == null || pubCache.isEmpty
        ? 'bge-goldens-pub-cache:/root/.pub-cache'
        : '$pubCache:/root/.pub-cache',
    if (owner != null) ...[
      '-e',
      'HOST_UID=${owner.uid}',
      '-e',
      'HOST_GID=${owner.gid}',
    ],
    '-e',
    'PACKAGES=${packages.join(' ')}',
    '-e',
    'UPDATE=${update ? '--update-goldens' : ''}',
    image,
    'bash',
    '-c',
    _containerScript,
  ]);

  final handedBack = _copyIntoCheckout(handBack, packages);
  handBack.deleteSync(recursive: true);
  if (handedBack.copied > 0) {
    stdout.writeln('Wrote ${handedBack.copied} file(s) under test/goldens/.');
  }
  if (handedBack.refused.isNotEmpty) {
    stderr.writeln(
      '\nThe container handed back ${handedBack.refused.length} path(s) '
      'outside a golden package\'s test/goldens/, or not a plain file. '
      'None were copied:',
    );
    for (final path in handedBack.refused) {
      stderr.writeln('  $path');
    }
    exit(1);
  }

  if (code != 0) {
    stderr.writeln(
      update
          ? '\nRegenerating the goldens failed.'
          : '\nGolden tests failed. The diffs are under each package\'s '
                'test/goldens/failures/.',
    );
    exit(1);
  }
}

/// Copies each file under [handBack] that sits in one of [packages]'
/// `test/goldens/` to the same relative path in the checkout. Returns how
/// many it copied, and the paths it refused.
///
/// The container script only hands back files from there, but `/out` is
/// writable from anything the container runs, tests and their
/// dependencies included. So the host holds the same line rather than
/// trusting it: anything else, or anything that isn't a plain file, such
/// as a link, stays out of the checkout.
({int copied, List<String> refused}) _copyIntoCheckout(
  Directory handBack,
  List<String> packages,
) {
  var copied = 0;
  final refused = <String>[];
  for (final entity in handBack.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final relative = entity.path.substring(handBack.path.length + 1);
    final posix = relative.replaceAll(Platform.pathSeparator, '/');
    final allowed =
        entity is File &&
        packages.any((p) => posix.startsWith('$p/test/goldens/'));
    if (!allowed) {
      refused.add(posix);
      continue;
    }
    File(relative).parent.createSync(recursive: true);
    entity.copySync(relative);
    copied++;
  }
  return (copied: copied, refused: refused);
}

/// The first 12 hex characters of a sha256 over [_imageInputs].
String _imageHash() {
  final bytes = <int>[
    for (final path in _imageInputs) ...File(path).readAsBytesSync(),
  ];
  return sha256.convert(bytes).toString().substring(0, 12);
}

/// Whether a docker client is installed and its daemon answers.
Future<bool> _dockerRunning() async {
  try {
    final result = await Process.run('docker', [
      'version',
      '--format',
      '{{.Server.Version}}',
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    // Not on PATH.
    return false;
  }
}

Future<bool> _imageExists(String image) async {
  final result = await Process.run('docker', ['image', 'inspect', image]);
  return result.exitCode == 0;
}

/// The packages that own tracked files under `test/goldens/`, sorted.
///
/// Discovered from git rather than from every package with a `test/`:
/// `flutter test --tags golden` exits 79 ("no tests ran") in a package with
/// no golden-tagged tests, which would fail the run. Put a new package's
/// goldens under `test/goldens/` or it is skipped.
Future<List<String>> _goldenPackages() async {
  final result = await Process.run('git', ['ls-files', '*/test/goldens/*']);
  if (result.exitCode != 0) {
    stderr.writeln('git ls-files failed:\n${result.stderr}');
    exit(1);
  }
  final packages = <String>{
    for (final line in (result.stdout as String).split('\n'))
      if (line.contains('/test/goldens/'))
        line.substring(0, line.indexOf('/test/goldens/')),
  };
  return packages.toList()..sort();
}

/// The host user's uid and gid, so the container can give the hand-back
/// directory to the host user, who has to delete it. Null on Windows,
/// which has neither.
Future<({String uid, String gid})?> _hostOwner() async {
  if (Platform.isWindows) return null;
  final uid = await Process.run('id', ['-u']);
  final gid = await Process.run('id', ['-g']);
  return (
    uid: (uid.stdout as String).trim(),
    gid: (gid.stdout as String).trim(),
  );
}

/// Runs [executable] with its output streamed to this process's, and
/// returns its exit code.
Future<int> _stream(String executable, List<String> arguments) async {
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
