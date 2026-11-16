// The shared workspace-root lookup the tool/ scripts run from (#808).
import 'dart:io';

import 'package:test/test.dart';

import '../src/workspace_root.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('workspace_root_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('finds the root from a nested directory', () {
    File(
      '${tmp.path}/pubspec.yaml',
    ).writeAsStringSync('name: w\nworkspace:\n  - a\n');
    final nested = Directory('${tmp.path}/a/b')..createSync(recursive: true);

    expect(workspaceRoot(from: nested).path, tmp.path);
  });

  test('throws WorkspaceRootNotFound when no workspace pubspec is above', () {
    expect(
      () => workspaceRoot(from: tmp),
      throwsA(
        isA<WorkspaceRootNotFound>().having(
          (e) => e.message,
          'message',
          contains('Run this from the repository.'),
        ),
      ),
    );
  });
}
