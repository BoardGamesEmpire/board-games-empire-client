// Pins check_sdk_constraints.dart's exit codes by running it over fixture
// workspaces (#201).
//
// The self-test (`--self-test`) pins the rewriters and checks one function
// at a time. What it cannot see is `main` deciding to exit 0: a `--fix`
// that reports success while leaving a tree the plain check still fails.
// So every case here runs both modes and requires them to agree.

import 'dart:io';

import 'package:test/test.dart';

import 'fixture_workspace.dart';

void main() {
  group('--fix exits 0 only when the tree it leaves passes the check', () {
    late Directory workspace;

    tearDown(() async {
      await workspace.delete(recursive: true);
    });

    /// Runs `--fix`, then the plain check, and returns both codes after
    /// asserting they agree.
    Future<(int, int)> fixThenCheck() async {
      final fix = await runTool(workspace, fix: true);
      final fixOutput = lastOutput;
      final check = await runTool(workspace);
      expect(
        fix,
        check,
        reason:
            '--fix exited $fix but the check after it exited $check.\n'
            '--fix said:\n$fixOutput\ncheck said:\n$lastOutput',
      );
      return (fix, check);
    }

    test('clean workspace', () async {
      workspace = await createFixtureWorkspace(
        members: {'packages/a': validMemberPubspec},
      );

      expect(await fixThenCheck(), (0, 0), reason: lastOutput);
    });

    test('rewritable sdk drift', () async {
      workspace = await createFixtureWorkspace(
        members: {
          'packages/a': validMemberPubspec.replaceFirst('^3.13.0', '^3.12.0'),
        },
      );

      expect(await runTool(workspace), 1, reason: lastOutput);
      expect(await fixThenCheck(), (0, 0), reason: lastOutput);
    });

    test('missing member', () async {
      workspace = await createFixtureWorkspace(
        members: {'packages/gone': null},
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
    });

    test('no environment block', () async {
      workspace = await createFixtureWorkspace(
        members: {
          'packages/a': 'name: a\npublish_to: none\nresolution: workspace\n',
        },
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
    });

    test('flow-style environment', () async {
      workspace = await createFixtureWorkspace(
        members: {
          'packages/a':
              'name: a\npublish_to: none\nenvironment: {}\n'
              'resolution: workspace\n',
        },
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
    });

    test('check-only problem', () async {
      workspace = await createFixtureWorkspace(
        members: {
          'packages/a': validMemberPubspec.replaceFirst(
            'publish_to: none\n',
            '',
          ),
        },
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
    });

    test('rewritable drift beside a check-only problem', () async {
      workspace = await createFixtureWorkspace(
        members: {
          'packages/a': validMemberPubspec
              .replaceFirst('^3.13.0', '^3.12.0')
              .replaceFirst('publish_to: none\n', ''),
        },
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
      // The rewrite still happened: only the check-only problem is left.
      expect(lastOutput, isNot(contains('SDK constraint drift')));
    });

    test('app version drift', () async {
      workspace = await createFixtureWorkspace(
        members: {
          'apps/app_a':
              'name: app_a\npublish_to: none\nversion: 0.9.0+1\n'
              'environment:\n  sdk: ^3.13.0\nresolution: workspace\n',
        },
      );

      expect(await runTool(workspace), 1, reason: lastOutput);
      expect(await fixThenCheck(), (0, 0), reason: lastOutput);
    });

    test('app version drift beside sdk drift in the same pubspec', () async {
      workspace = await createFixtureWorkspace(
        members: {
          'apps/app_a':
              'name: app_a\npublish_to: none\nversion: 0.9.0+1\n'
              'environment:\n  sdk: ^3.12.0\nresolution: workspace\n',
        },
      );

      expect(await runTool(workspace), 1, reason: lastOutput);
      // The environment rewrite starts from the version rewrite's text, so
      // both survive.
      expect(await fixThenCheck(), (0, 0), reason: lastOutput);
    });

    // The rewriters edit lines, so a folded value's continuation survives
    // them and joins the new value. Only re-reading the rewrite catches
    // that, and these two cases are what fail if `main` stops doing so.
    test('folded sdk value the rewrite cannot replace', () async {
      const pubspec =
          'name: a\npublish_to: none\nenvironment:\n  sdk: >-\n'
          '    ^3.12.0\nresolution: workspace\n';
      workspace = await createFixtureWorkspace(
        members: {'packages/a': pubspec},
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
      expect(
        File('${workspace.path}/packages/a/pubspec.yaml').readAsStringSync(),
        pubspec,
      );
    });

    test('folded app version the rewrite cannot replace', () async {
      const pubspec =
          'name: app_a\npublish_to: none\nversion: >-\n  0.9.0+1\n'
          'environment:\n  sdk: ^3.13.0\nresolution: workspace\n';
      workspace = await createFixtureWorkspace(
        members: {'apps/app_a': pubspec},
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
      expect(
        File('${workspace.path}/apps/app_a/pubspec.yaml').readAsStringSync(),
        pubspec,
      );
    });

    test('stale digest', () async {
      workspace = await createFixtureWorkspace(
        flutterDigest: validFlutterDigest.replaceFirst('3.47.1', '3.44.4'),
      );

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
      // A bump that forgot the file says where the new digest comes from,
      // rather than failing later as a download mismatch in CI.
      expect(lastOutput, contains('releases_linux.json'));
    });

    test('missing digest', () async {
      workspace = await createFixtureWorkspace(flutterDigest: '');

      expect(await fixThenCheck(), (1, 1), reason: lastOutput);
    });
  });
}
