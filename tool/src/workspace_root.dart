import 'dart:io';

/// The workspace root: the nearest directory at or above [from], the
/// current directory by default, whose pubspec.yaml declares a
/// `workspace:`.
///
/// Found by reading the pubspec rather than by assuming the working
/// directory, so a script run from inside a package still finds it (#808).
/// Looks at the start directory and at most seven above it, and throws
/// [WorkspaceRootNotFound] when none of them is the root.
Directory workspaceRoot({Directory? from}) {
  final start = from ?? Directory.current;
  var dir = start;
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
  throw WorkspaceRootNotFound(start.path);
}

/// No directory at or above [workspaceRoot]'s start is the workspace root.
///
/// Each script decides what that means for it: the build scripts print
/// [message] and exit 1, and release_tags throws its own exception.
final class WorkspaceRootNotFound implements Exception {
  /// The lookup that started at [from] found no workspace root.
  WorkspaceRootNotFound(String from)
    : message =
          'Could not locate the workspace root from $from. '
          'Run this from the repository.';

  /// What to tell the person who ran the script.
  final String message;

  @override
  String toString() => message;
}
