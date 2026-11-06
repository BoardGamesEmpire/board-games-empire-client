// Builds throwaway workspaces for check_sdk_constraints_test.dart and runs
// the real tool over them (#201).
//
// The tool's `main` calls `exit`, so its exit codes can only be observed
// from outside the process. Each case writes a small workspace into a temp
// directory and runs `dart run tool/check_sdk_constraints.dart` there as a
// subprocess, with the repo's own package config so `package:yaml`
// resolves without a `pub get` in the fixture.

import 'dart:io';
import 'dart:isolate';

/// The repo's package config, which the tool runs under so `package:yaml`
/// resolves without a `pub get` in the fixture.
///
/// Taken from the test isolate, never the cwd. `Platform.script` can't
/// stand in for the suite's own path here: under `dart test` it names a
/// kernel file in the system temp directory.
final File packageConfig = File.fromUri(Isolate.packageConfigSync!);

/// The repo root: the directory holding the `.dart_tool/` that
/// [packageConfig] sits in.
final Directory repoRoot = () {
  final root = packageConfig.parent.parent;
  if (!File('${root.path}/tool/check_sdk_constraints.dart').existsSync()) {
    throw StateError(
      'No tool/check_sdk_constraints.dart beside ${packageConfig.path}.',
    );
  }
  return root;
}();

/// A member pubspec that passes every invariant: the root's sdk, no
/// Flutter dependency (so no `flutter:` key), and `publish_to: none`.
const validMemberPubspec = '''
name: member
publish_to: none
environment:
  sdk: ^3.13.0
resolution: workspace
''';

/// Writes a workspace into a new temp directory and returns it.
///
/// [members] maps a directory, relative to the root, to its pubspec text.
/// Every key is listed in the root `workspace:`; a `null` value lists the
/// directory without creating it. A valid `apps/app_a` is always present,
/// because the tool refuses a workspace with no app.
///
/// Registers no teardown: the caller deletes the directory.
Future<Directory> createFixtureWorkspace({
  Map<String, String?> members = const {},
  String rootPubspecExtra = '',
}) async {
  final root = await Directory.systemTemp.createTemp('check_sdk_fixture_');
  final all = <String, String?>{
    'apps/app_a': '''
name: app_a
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.13.0
resolution: workspace
''',
    ...members,
  };

  final rootPubspec = StringBuffer('''
name: fixture_root
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.13.0
  flutter: 3.47.1
workspace:
''');
  for (final dir in all.keys) {
    rootPubspec.writeln('  - $dir');
  }
  rootPubspec.write(rootPubspecExtra);
  await File('${root.path}/pubspec.yaml').writeAsString('$rootPubspec');

  for (final MapEntry(key: dir, value: pubspec) in all.entries) {
    if (pubspec == null) continue;
    final file = File('${root.path}/$dir/pubspec.yaml');
    await file.parent.create(recursive: true);
    await file.writeAsString(pubspec);
  }

  return root;
}

/// Runs the real check in [cwd], with `--fix` when [fix] is set, and
/// returns its exit code.
///
/// Output goes nowhere unless the run surprises the caller, so it is kept
/// on [lastOutput] for a failing expectation's reason.
Future<int> runTool(Directory cwd, {bool fix = false}) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    '--packages=${packageConfig.path}',
    '${repoRoot.path}/tool/check_sdk_constraints.dart',
    if (fix) '--fix',
  ], workingDirectory: cwd.path);
  lastOutput = '${result.stdout}${result.stderr}';
  return result.exitCode;
}

/// The combined stdout and stderr of the last [runTool] call.
String lastOutput = '';
