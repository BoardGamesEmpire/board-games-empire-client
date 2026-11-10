// Builds the Android release APK the way CI does, for both
// `melos run build-mobile-android` and CI's `build-android` job (#51). One
// definition, so a local release build is CI's build.
//
// Usage, from the workspace root:
//   dart run tool/build_android.dart
//   dart run tool/build_android.dart --require-release-signing
//   dart run tool/build_android.dart --build-number 214
//   dart run tool/build_android.dart --self-test   # the fixtures, no build
//
// ── What it does ────────────────────────────────────────────────────
//
//   1. Reads the app's `version:` and refuses one that is not
//      major.minor.patch+build, before spending a build on it. The APK is
//      named for the version without its build number:
//      bge-<X.Y.Z>-android-universal.apk. With `--build-number <n>`, the
//      build is given n in place of the committed build number, which stays
//      1: CI passes its commit count, so each build's versionCode only
//      rises (#419).
//   2. Empties apps/mobile/build/release. CI uploads the whole directory,
//      and an APK an earlier build left there, another version's, would
//      ship beside the current one.
//   3. Builds one universal release APK: every ABI in one file, so a user
//      sideloading it never has to pick one. With
//      `--require-release-signing`, the build runs with
//      BGE_REQUIRE_RELEASE_SIGNING=true, and Gradle fails rather than fall
//      back to the debug key.
//   4. Checks the APK itself, with the build-tools' aapt2 and apksigner:
//      - its package is com.boardgamesempire.app;
//      - its versionCode is the `--build-number` given, when one is;
//      - it holds android.permission.INTERNET. Flutter's template grants
//        it only in the debug and profile manifests, so a release build
//        had no network at all, and nothing in `flutter run` shows that.
//        Only the artifact does;
//      - its signature verifies, and the signer is printed. With
//        `--require-release-signing`, any signer but the release key
//        fails the build: Android refuses an APK as an update over one
//        signed with another key, so every installed copy would turn it
//        away. The release key is the certificate [_releaseCertificate]
//        names. A debug key fails it, and so does a valid key that only
//        stands in for the release one, such as a replaced CI secret.
//   5. Copies the APK to apps/mobile/build/release under its versioned
//      name, beside a `.sha256` in `sha256sum -c` format.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

const _app = 'apps/mobile';

const _package = 'com.boardgamesempire.app';

const _flags = <String>['build', 'apk', '--release'];

/// Where `flutter build apk --release` writes the APK, relative to the app.
const _builtApk = 'build/app/outputs/flutter-apk/app-release.apk';

/// The directory CI uploads, relative to the app.
const _uploadDir = 'build/release';

const _requireReleaseSigning = '--require-release-signing';

const _buildNumberFlag = '--build-number';

const _usage =
    'Usage: dart run tool/build_android.dart '
    '[$_requireReleaseSigning] [$_buildNumberFlag <n>] | --self-test';

/// The SHA-256 digest of the release key's certificate, as `keytool -list
/// -v` prints it. Every APK CI ships is signed by it, and only an APK that
/// is installs over one already out there.
///
/// Kept here, not beside the key in CI's secrets, so that changing which key
/// CI ships takes a reviewed change to master, not only a new secret.
/// docs/dev/android-signing.md records it when the key is made.
const _releaseCertificate =
    '52:96:99:C0:55:A9:87:79:CC:BB:26:23:B4:11:6E:79:'
    'E0:30:D5:1C:EB:13:E8:F9:4E:23:5E:F1:10:FA:4B:50';

Future<void> main(List<String> args) async {
  final unknown = <String>[];
  int? buildNumber;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == _buildNumberFlag) {
      // The flag's value is the next argument, whatever it looks like: a
      // bad one is reported as a bad build number, not as an unknown flag.
      if (i + 1 >= args.length) {
        stderr.writeln('$_buildNumberFlag needs a value.');
        stderr.writeln(_usage);
        exit(64); // EX_USAGE
      }
      try {
        buildNumber = _parseBuildNumber(args[++i]);
      } on FormatException catch (e) {
        stderr.writeln('$_buildNumberFlag: ${e.message} (${e.source}).');
        stderr.writeln(_usage);
        exit(64); // EX_USAGE
      }
    } else if (a != '--self-test' && a != _requireReleaseSigning) {
      unknown.add(a);
    }
  }
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument(s): ${unknown.join(', ')}');
    stderr.writeln(_usage);
    exit(64); // EX_USAGE
  }

  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }

  final requireReleaseSigning = args.contains(_requireReleaseSigning);
  final app = Directory('${_workspaceRoot().path}/$_app');

  final pubspec = File('${app.path}/pubspec.yaml');
  final version = (loadYaml(pubspec.readAsStringSync()) as YamlMap)['version']
      ?.toString();
  final String name;
  try {
    name = _apkName(version ?? '');
  } on FormatException {
    stderr.writeln(
      '$_app/pubspec.yaml has version ${version ?? '(absent)'}, and the APK '
      'is named for a major.minor.patch+build version.',
    );
    exit(1);
  }

  final output = Directory('${app.path}/$_uploadDir');
  if (output.existsSync()) output.deleteSync(recursive: true);
  output.createSync(recursive: true);

  final flutterArgs = [
    ..._flags,
    if (buildNumber != null) '$_buildNumberFlag=$buildNumber',
  ];
  final flutter = await Process.start(
    'flutter',
    flutterArgs,
    workingDirectory: app.path,
    environment: {
      if (requireReleaseSigning) 'BGE_REQUIRE_RELEASE_SIGNING': 'true',
    },
    mode: ProcessStartMode.inheritStdio,
    // `flutter` is a batch file on Windows, which needs a shell to start.
    runInShell: Platform.isWindows,
  );
  final code = await flutter.exitCode;
  if (code != 0) {
    stderr.writeln(
      'flutter ${flutterArgs.join(' ')} failed with exit code $code.',
    );
    exit(code);
  }

  final apk = File('${app.path}/$_builtApk');
  if (!apk.existsSync()) {
    stderr.writeln(
      'flutter ${flutterArgs.join(' ')} succeeded but wrote no '
      '$_app/$_builtApk.',
    );
    exit(1);
  }

  // Read after the build, which writes local.properties.
  final localProperties = File('${app.path}/android/local.properties');
  final sdk = _sdkDir(
    Platform.environment,
    localProperties.existsSync() ? localProperties.readAsStringSync() : null,
  );
  if (sdk == null) {
    stderr.writeln(
      'Found no Android SDK to check the APK with: $_app/android/'
      'local.properties has no sdk.dir, and neither ANDROID_HOME nor '
      'ANDROID_SDK_ROOT is set.',
    );
    exit(1);
  }
  final tools = _buildTools(sdk);

  final badging = await _run(tools.aapt2, ['dump', 'badging', apk.path]);
  final problems = _badgingProblems(badging, versionCode: buildNumber);
  if (problems.isNotEmpty) {
    stderr.writeln('The release APK is not the app CI ships:');
    for (final p in problems) {
      stderr.writeln('  $p');
    }
    exit(1);
  }

  final certs = await _run(tools.apksigner, [
    'verify',
    '--print-certs',
    apk.path,
  ]);
  for (final line in const LineSplitter().convert(certs)) {
    if (line.contains('certificate DN:')) stdout.writeln(line);
  }
  if (requireReleaseSigning && _isDebugSigner(certs)) {
    stderr.writeln(
      'The APK is signed with the debug key, though $_requireReleaseSigning '
      'was given. It would not install over a release-signed build.',
    );
    exit(1);
  }
  if (requireReleaseSigning) {
    final signerProblems = _signerProblems(certs, _releaseCertificate);
    if (signerProblems.isNotEmpty) {
      stderr.writeln(
        'The APK is not signed with the release key, though '
        '$_requireReleaseSigning was given. It would not install over a '
        'release-signed build:',
      );
      for (final p in signerProblems) {
        stderr.writeln('  $p');
      }
      stderr.writeln(
        'If the release key was replaced on purpose, change '
        '_releaseCertificate in tool/build_android.dart; '
        'docs/dev/android-signing.md says what that costs.',
      );
      exit(1);
    }
  }

  final bytes = apk.readAsBytesSync();
  File('${output.path}/$name').writeAsBytesSync(bytes);
  File('${output.path}/$name.sha256')
      .writeAsStringSync(_sha256Line(bytes, name));
  stdout.writeln('$_app/$_uploadDir: $name and its .sha256, ready to upload.');
}

/// The workspace root, identified by reading its pubspec rather than by
/// assuming the working directory, as tool/build_web.dart does.
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

/// Runs [executable] and returns its stdout, or ends the build with its
/// output when it fails.
Future<String> _run(String executable, List<String> args) async {
  final result = await Process.run(
    executable,
    args,
    // apksigner is a batch file on Windows.
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    stderr
      ..writeln(
        '${executable.split(Platform.pathSeparator).last} ${args.join(' ')} '
        'failed with exit code ${result.exitCode}:',
      )
      ..write(result.stdout)
      ..write(result.stderr);
    exit(1);
  }
  return result.stdout as String;
}

/// The newest build-tools under [sdk] that hold both aapt2 and apksigner.
({String aapt2, String apksigner}) _buildTools(String sdk) {
  final aapt2 = Platform.isWindows ? 'aapt2.exe' : 'aapt2';
  final apksigner = Platform.isWindows ? 'apksigner.bat' : 'apksigner';
  final root = Directory('$sdk/build-tools');
  final versions = [
    if (root.existsSync())
      for (final dir in root.listSync().whereType<Directory>())
        if (File('${dir.path}/$aapt2').existsSync() &&
            File('${dir.path}/$apksigner').existsSync())
          dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
  ]..sort(_compareVersions);
  if (versions.isEmpty) {
    stderr.writeln(
      'No build-tools under $sdk hold both aapt2 and apksigner, which check '
      'the APK. Install one with sdkmanager "build-tools;<version>".',
    );
    exit(1);
  }
  final dir = '${root.path}/${versions.last}';
  return (aapt2: '$dir/$aapt2', apksigner: '$dir/$apksigner');
}

/// Orders build-tools directory names by their numbers, so 36.1.0 sorts
/// after 4.0.0 and before 37.0.0, and a preview (37.0.0-rc1) before the
/// release it precedes, so a release is picked over its own previews.
int _compareVersions(String a, String b) {
  List<int> numbers(String v) => [
    for (final m in RegExp(r'\d+').allMatches(v)) int.parse(m[0]!),
  ];
  int compareNumbers(List<int> x, List<int> y) {
    for (var i = 0; i < x.length && i < y.length; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return x.length.compareTo(y.length);
  }

  final [aRelease, ...aPreview] = a.split('-');
  final [bRelease, ...bPreview] = b.split('-');
  final byRelease = compareNumbers(numbers(aRelease), numbers(bRelease));
  if (byRelease != 0) return byRelease;
  if (aPreview.isEmpty != bPreview.isEmpty) return aPreview.isEmpty ? 1 : -1;
  final byPreview = compareNumbers(
    numbers(aPreview.join('-')),
    numbers(bPreview.join('-')),
  );
  return byPreview != 0 ? byPreview : a.compareTo(b);
}

/// The APK's file name for the app's [version]: the version without its
/// build number, which only Android's versionCode carries.
///
/// Throws a [FormatException] unless [version] is major.minor.patch+build,
/// the shape check_sdk_constraints holds the root `version:` to.
String _apkName(String version) {
  final match = RegExp(r'^(\d+\.\d+\.\d+)\+\d+$').firstMatch(version);
  if (match == null) {
    throw FormatException('Not major.minor.patch+build', version);
  }
  return 'bge-${match[1]}-android-universal.apk';
}

/// [bytes]' SHA-256 as `sha256sum -c` reads it: the digest, two spaces,
/// the file name.
String _sha256Line(List<int> bytes, String name) =>
    '${sha256.convert(bytes)}  $name\n';

/// [raw] as the build number `--build-number` passes to Flutter: digits
/// only, from 1 to 65535.
///
/// The ceiling is the one a Windows build's version field has, which #439
/// holds every platform's build number to, so a count CI could pass here
/// never outgrows what another platform takes.
///
/// Throws a [FormatException] for anything else.
int _parseBuildNumber(String raw) {
  final number = RegExp(r'^\d+$').hasMatch(raw) ? int.parse(raw) : null;
  if (number == null || number < 1 || number > 65535) {
    throw FormatException('Not a build number from 1 to 65535', raw);
  }
  return number;
}

/// What is wrong with an APK, given `aapt2 dump badging`'s output.
///
/// Empty when its package is [_package] and it holds the INTERNET
/// permission, and, when [versionCode] is given, when that is its
/// versionCode too.
List<String> _badgingProblems(String badging, {int? versionCode}) {
  final lines = const LineSplitter().convert(badging);
  final problems = <String>[];
  final packageLine = lines.where((l) => l.startsWith('package:')).firstOrNull;
  if (packageLine == null) {
    problems.add("no package line in aapt2's badging output");
  } else {
    final actual = RegExp(r"\bname='([^']*)'").firstMatch(packageLine)?[1];
    if (actual != _package) {
      problems.add('package is ${actual ?? '(unnamed)'}, not $_package');
    }
    if (versionCode != null) {
      final code = RegExp(r"\bversionCode='([^']*)'")
          .firstMatch(packageLine)?[1];
      if (code == null) {
        problems.add('no versionCode');
      } else if (code != '$versionCode') {
        problems.add('versionCode is $code, not $versionCode');
      }
    }
  }
  final internet = RegExp(
    r"^uses-permission: name='android\.permission\.INTERNET'(\s|$)",
  );
  if (!lines.any(internet.hasMatch)) {
    problems.add(
      'no android.permission.INTERNET: a release build could not reach any '
      'server',
    );
  }
  return problems;
}

/// Whether `apksigner verify --print-certs` names the debug key, whose
/// certificate Android's tooling always issues to CN=Android Debug.
bool _isDebugSigner(String printCerts) => const LineSplitter()
    .convert(printCerts)
    .any(
      (l) => l.contains('certificate DN:') && l.contains('CN=Android Debug'),
    );

/// What keeps an APK's signers from being the release key, given `apksigner
/// verify --print-certs`' output: empty when every signer's certificate
/// SHA-256 digest is [expected].
///
/// [expected] may be in `keytool`'s form, colon-separated upper case, and
/// apksigner prints bare lower case; both are compared without either. A
/// public key's digest, which `-v` adds, and a source stamp's, which is
/// not a signer, are not a signer's certificate.
List<String> _signerProblems(String printCerts, String expected) {
  String bare(String digest) =>
      digest.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();
  final want = bare(expected);
  final certificate = RegExp(r'\bcertificate SHA-256 digest: ([0-9a-fA-F:]+)');
  final digests = [
    for (final line in const LineSplitter().convert(printCerts))
      if (!line.startsWith('Source Stamp'))
        if (certificate.firstMatch(line) case final match?) bare(match[1]!),
  ];
  if (digests.isEmpty) {
    return ["no signer's certificate SHA-256 digest in apksigner's output"];
  }
  return [
    for (final digest in digests)
      if (digest != want)
        'a signer certificate has SHA-256 digest $digest, not the release '
            "key's $want",
  ];
}

/// The Android SDK to take build-tools from: `sdk.dir` in
/// [localProperties], else ANDROID_HOME, else ANDROID_SDK_ROOT.
///
/// The order the Android Gradle plugin uses, so the tools come from the
/// SDK the APK was built with. Flutter writes `sdk.dir` for the SDK it
/// found, escaped as java.util.Properties reads it.
String? _sdkDir(Map<String, String> env, String? localProperties) {
  String? fromProperties;
  for (final line in const LineSplitter().convert(localProperties ?? '')) {
    final match = RegExp(r'^\s*sdk\.dir\s*[=:]\s*(.*?)\s*$').firstMatch(line);
    // The last one wins, as in java.util.Properties.
    if (match != null) {
      fromProperties = match[1]!.replaceAllMapped(
        RegExp(r'\\(.)'),
        (m) => m[1]!,
      );
    }
  }
  if (fromProperties != null && fromProperties.isNotEmpty) {
    return fromProperties;
  }
  for (final key in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
    final value = env[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// Fixture tests for the pure functions the build relies on.
///
/// Each one decides whether a build passes, and the real build only ever
/// meets the tree's own APK, so the shapes each must accept and refuse are
/// pinned here. Run by CI's `build-android` job.
void _selfTest() {
  var failures = 0;

  // Compared as JSON so the problem lists are pinned the same way as the
  // strings.
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

  void expectFormatException(String name, void Function() body) {
    try {
      body();
      failures++;
      stdout.writeln('  FAIL $name: no FormatException');
    } on FormatException {
      stdout.writeln('  ok   $name');
    }
  }

  expect(
    'name: drops the build number',
    _apkName('1.0.0+1'),
    'bge-1.0.0-android-universal.apk',
  );
  expect(
    'name: keeps every part of the version',
    _apkName('0.1.0+2'),
    'bge-0.1.0-android-universal.apk',
  );
  expectFormatException(
    'name: refuses a version with no build number',
    () => _apkName('1.0.0'),
  );
  expectFormatException(
    'name: refuses a prerelease version',
    () => _apkName('1.0.0-beta+1'),
  );

  expect(
    'checksum: sha256sum -c format',
    _sha256Line(utf8.encode('abc'), 'x.apk'),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  '
        'x.apk\n',
  );

  const packageLine =
      "package: name='com.boardgamesempire.app' versionCode='1' "
      "versionName='1.0.0' platformBuildVersionName='16'\n";
  const internetLine = "uses-permission: name='android.permission.INTERNET'\n";
  const otherLines =
      "sdkVersion:'24'\n"
      "targetSdkVersion:'36'\n"
      "application-label:'Board Games Empire'\n";
  const okBadging = '$packageLine$otherLines$internetLine';

  expect(
    'badging: accepts the package with INTERNET',
    _badgingProblems(okBadging),
    <String>[],
  );
  expect(
    "badging: names the template's package",
    _badgingProblems(
      okBadging.replaceFirst(_package, 'com.boardgamesempire.mobile.mobile'),
    ),
    [
      'package is com.boardgamesempire.mobile.mobile, not '
          'com.boardgamesempire.app',
    ],
  );
  expect(
    'badging: flags a release build with no network',
    _badgingProblems('$packageLine$otherLines'),
    [
      'no android.permission.INTERNET: a release build could not reach any '
          'server',
    ],
  );
  expect(
    'badging: flags output with no package line',
    _badgingProblems('$otherLines$internetLine'),
    ["no package line in aapt2's badging output"],
  );
  // A permission that only starts with INTERNET is another permission.
  expect(
    'badging: does not take a longer permission for INTERNET',
    _badgingProblems(
      '$packageLine$otherLines'
      "uses-permission: name='android.permission.INTERNET_EXTRA'\n",
    ),
    [
      'no android.permission.INTERNET: a release build could not reach any '
          'server',
    ],
  );

  final numberedBadging = okBadging.replaceFirst(
    "versionCode='1'",
    "versionCode='214'",
  );
  expect(
    'badging: accepts the versionCode asked for',
    _badgingProblems(numberedBadging, versionCode: 214),
    <String>[],
  );
  expect(
    'badging: names a versionCode other than the one asked for',
    _badgingProblems(numberedBadging, versionCode: 7),
    ['versionCode is 214, not 7'],
  );
  expect(
    'badging: checks no versionCode when none is asked for',
    _badgingProblems(numberedBadging),
    <String>[],
  );
  expect(
    'badging: flags a package line with no versionCode',
    _badgingProblems(
      numberedBadging.replaceFirst("versionCode='214' ", ''),
      versionCode: 214,
    ),
    ['no versionCode'],
  );

  expect('build number: accepts a CI count', _parseBuildNumber('214'), 214);
  expect(
    'build number: accepts the largest a Windows build takes',
    _parseBuildNumber('65535'),
    65535,
  );
  for (final raw in const ['0', '65536', '21a', '', '-3']) {
    expectFormatException(
      "build number: refuses '$raw'",
      () => _parseBuildNumber(raw),
    );
  }

  expect(
    'signer: the debug key',
    _isDebugSigner(
      'Signer #1 certificate DN: C=US, O=Android, CN=Android Debug\n'
      'Signer #1 certificate SHA-256 digest: 00\n',
    ),
    true,
  );
  // build-tools 37 names the scheme in place of the signer's number.
  expect(
    'signer: the debug key as build-tools 37 prints it',
    _isDebugSigner(
      'V2 Signer: certificate DN: C=US, O=Android, CN=Android Debug\n'
      'V2 Signer: certificate SHA-256 digest: 00\n',
    ),
    true,
  );
  expect(
    'signer: a release key',
    _isDebugSigner(
      'Signer #1 certificate DN: CN=BGE release\n'
      'Signer #1 certificate SHA-256 digest: 00\n',
    ),
    false,
  );

  // An expected certificate as keytool prints it, the form
  // _releaseCertificate takes, and the same digest as apksigner prints it;
  // then another key's, from real apksigner output. Fixtures, not
  // _releaseCertificate, so a new release key changes only the constant.
  const keytoolDigest =
      '52:96:99:C0:55:A9:87:79:CC:BB:26:23:B4:11:6E:79:'
      'E0:30:D5:1C:EB:13:E8:F9:4E:23:5E:F1:10:FA:4B:50';
  const releaseDigest =
      '529699c055a98779ccbb2623b4116e79e030d51ceb13e8f94e235ef110fa4b50';
  const otherDigest =
      '92fe8a6fc5c6b4445cf7d9cc1942279a0bb5ee548126a571506ceada6bd2ffdd';
  expect(
    "release signer: accepts the expected key in keytool's form",
    _signerProblems(
      'Signer #1 certificate SHA-256 digest: $releaseDigest\n',
      keytoolDigest,
    ),
    <String>[],
  );
  expect(
    'release signer: the release key in output with no signer number',
    _signerProblems(
      'WARNING: A restricted method in java.lang.System has been called\n'
      '\n'
      'V2 Signer: certificate DN: CN=Board Games Empire\n'
      'V2 Signer: certificate SHA-256 digest: $releaseDigest\n'
      'V2 Signer: certificate SHA-1 digest: 89779bfaed00c066b3cfff42d1441eeb\n',
      keytoolDigest,
    ),
    <String>[],
  );
  expect(
    'release signer: refuses another valid key',
    _signerProblems(
      'V2 Signer: certificate DN: CN=BGE throwaway\n'
      'V2 Signer: certificate SHA-256 digest: $otherDigest\n',
      keytoolDigest,
    ),
    [
      'a signer certificate has SHA-256 digest $otherDigest, not the '
          "release key's $releaseDigest",
    ],
  );
  expect(
    'release signer: refuses a second signer that is another key',
    _signerProblems(
      'Signer #1 certificate SHA-256 digest: $releaseDigest\n'
      'Signer #2 certificate SHA-256 digest: $otherDigest\n',
      keytoolDigest,
    ),
    [
      'a signer certificate has SHA-256 digest $otherDigest, not the '
          "release key's $releaseDigest",
    ],
  );
  expect(
    "release signer: not the public key's digest -v adds",
    _signerProblems(
      'V2 Signer: certificate SHA-256 digest: $releaseDigest\n'
      'V2 Signer: public key SHA-256 digest: $otherDigest\n',
      keytoolDigest,
    ),
    <String>[],
  );
  expect(
    "release signer: not a source stamp's certificate",
    _signerProblems(
      'Signer #1 certificate SHA-256 digest: $releaseDigest\n'
      'Source Stamp Signer certificate SHA-256 digest: $otherDigest\n',
      keytoolDigest,
    ),
    <String>[],
  );
  expect(
    'release signer: flags output naming no certificate',
    _signerProblems('Verified using v2 scheme: true\n', keytoolDigest),
    ["no signer's certificate SHA-256 digest in apksigner's output"],
  );
  expect(
    "release signer: _releaseCertificate is a SHA-256 digest in keytool's form",
    RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$').hasMatch(_releaseCertificate),
    true,
  );

  expect(
    "sdk: local.properties' sdk.dir, which Gradle reads first",
    _sdkDir({'ANDROID_HOME': '/a'}, 'sdk.dir=/b\n'),
    '/b',
  );
  expect(
    'sdk: sdk.dir among the other properties',
    _sdkDir(const {}, 'flutter.sdk=/f\nsdk.dir=/b\n'),
    '/b',
  );
  expect(
    'sdk: ANDROID_HOME without a local.properties',
    _sdkDir({'ANDROID_HOME': '/a', 'ANDROID_SDK_ROOT': '/c'}, null),
    '/a',
  );
  expect(
    'sdk: ANDROID_HOME when local.properties has no sdk.dir',
    _sdkDir({'ANDROID_HOME': '/a'}, 'flutter.sdk=/f\n'),
    '/a',
  );
  expect(
    'sdk: ANDROID_SDK_ROOT on its own',
    _sdkDir({'ANDROID_SDK_ROOT': '/c'}, null),
    '/c',
  );
  expect('sdk: none', _sdkDir(const {}, null), null);
  // Flutter escapes the path the way java.util.Properties reads it.
  expect(
    'sdk: an escaped Windows path',
    _sdkDir(
      const {},
      r'sdk.dir=C\:\\Users\\a\\sdk'
      '\r\n',
    ),
    r'C:\Users\a\sdk',
  );

  expect(
    'build-tools: newest by number, not by string',
    (['9.0.0', '37.0.0', '36.1.0', '4.0.0']..sort(_compareVersions)).last,
    '37.0.0',
  );
  expect(
    'build-tools: a release above its own previews',
    (['37.0.0', '37.0.0-rc1', '36.1.0']..sort(_compareVersions)).last,
    '37.0.0',
  );
  expect(
    'build-tools: previews by number, rc10 above rc2',
    (['37.0.0-rc10', '37.0.0-rc2', '36.1.0']..sort(_compareVersions)).last,
    '37.0.0-rc10',
  );

  if (failures > 0) {
    stderr.writeln('\n$failures self-test failure(s).');
    exit(1);
  }
  stdout.writeln('build_android self-test passed.');
}
