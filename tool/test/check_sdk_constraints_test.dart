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
  });
}
