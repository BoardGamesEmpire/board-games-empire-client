/// The fields a class declares, read from its source.
///
/// Shared by the equality tests for `BgeTokens` and `BgeStatusColors` (#212).
/// Each keeps one case per field, and checks those cases against this rather
/// than against another hand-kept list, so a field missing from both the
/// class's `_fields` and the test's cases still fails.
library;

import 'dart:io';

/// The names of the instance fields declared in [file], a path under this
/// package's `lib/src/`.
///
/// Matches a `final` at class-member indent, so a local `final` inside a
/// method body is not counted.
Set<String> declaredFields(String file) {
  final source = File(
    '${Directory.current.path}/lib/src/$file',
  ).readAsStringSync();
  return RegExp(
    r'^  final \S+ (\w+)(?:;| =)',
    multiLine: true,
  ).allMatches(source).map((m) => m[1]!).toSet();
}
