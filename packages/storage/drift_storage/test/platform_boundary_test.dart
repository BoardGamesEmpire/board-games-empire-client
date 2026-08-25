// Executable form of #287's acceptance criterion: the platform-neutral
// entry point of this package must be importable from a web target.
//
// A `flutter build web` would prove it end-to-end but costs a full web
// toolchain run and only fails *after* someone has already shipped the
// import. This walks the transitive source closure of each entry point
// instead — the same closure the compiler would walk — and fails on the
// file that reintroduced the native dependency, which is the fact a
// reviewer needs.
//
// The check is source-level on purpose: it reads this package's own `lib/`
// files and does not resolve into other packages. `drift/drift.dart`,
// `flutter/foundation.dart` and friends are conditionally-imported,
// web-safe libraries; the thing that breaks a web build is *this* package
// naming a VM-only library directly.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `dart:` libraries that do not exist on web.
const _vmOnlyDartLibraries = {
  'dart:io',
  'dart:ffi',
  'dart:isolate',
  'dart:mirrors',
  'dart:cli',
};

/// Packages with no web implementation at all: **every** library in them is
/// disqualifying, not just the one that happens to be imported today. Match
/// by package rather than by exact URI so a sibling library
/// (`package:sqlite3/open.dart` beside `package:sqlite3/sqlite3.dart`) cannot
/// slip through.
const _vmOnlyPackages = {
  'sqlite3',
  'sqlite3_flutter_libs',
  'path_provider',
  'path_provider_foundation',
  'path_provider_android',
};

/// Packages that ship *both* web-safe and VM-only libraries, listed as the
/// set of libraries that ARE web-safe. Anything else in these packages is
/// treated as VM-only — a deny-list would silently miss a native library
/// added upstream, and a false positive here is one line to fix with the
/// offending file named.
const _webSafeLibrariesByPackage = {
  'drift': {
    'drift.dart',
    'wasm.dart',
    'web.dart',
    'remote.dart',
    'backends.dart',
    'extensions/json1.dart',
    'internal/versioned_schema.dart',
  },
};

/// Whole `import`/`export`/`part` directives, keyword through `;`, so a
/// directive wrapped across lines by `dart format` is still one match. A
/// full parse would pull in `analyzer` for no extra signal.
final _directive = RegExp(
  r'^[ \t]*(?:import|export|part)\b[^;]*;',
  multiLine: true,
);

/// Every quoted URI inside one directive. A conditional import names more
/// than one — `import 'x_web.dart' if (dart.library.io) 'x_io.dart';` — and
/// reading only the first would let the VM-only branch into the closure
/// unexamined.
final _directiveUri = RegExp(r'''\'([^\']+)\'|"([^"]+)"''');

/// Why [uri] cannot appear in a web-importable closure, or null if it can.
String? _vmOnlyReason(String uri) {
  if (_vmOnlyDartLibraries.contains(uri)) return uri;
  if (!uri.startsWith('package:')) return null;

  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash < 0) return null;
  final package = rest.substring(0, slash);
  final library = rest.substring(slash + 1);

  if (_vmOnlyPackages.contains(package)) return 'package:$package (VM-only)';

  final webSafe = _webSafeLibrariesByPackage[package];
  if (webSafe != null && !webSafe.contains(library)) {
    return '$uri (not a web-safe $package library)';
  }
  return null;
}

/// This package's root, located from the pub workspace root rather than
/// from the working directory: `flutter test` inside the package and
/// `flutter test <path>` from the workspace root have different cwds, and a
/// cwd-relative walk finds the workspace pubspec in the second case and
/// silently scans nothing.
///
/// Follows `_workspaceRoot()` in
/// `packages/ui/tokens/test/design_system_enforcement_test.dart`: identify a
/// directory by reading its pubspec, never by assuming the path is right.
Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      final contents = pubspec.readAsStringSync();
      // Already inside the package (the common `flutter test` case).
      if (contents.contains('name: drift_storage')) return dir;
      // At the workspace root: descend to the package by its known path.
      if (contents.contains('\nworkspace:')) {
        final package = Directory('${dir.path}/packages/storage/drift_storage');
        final packagePubspec = File('${package.path}/pubspec.yaml');
        if (packagePubspec.existsSync() &&
            packagePubspec.readAsStringSync().contains('name: drift_storage')) {
          return package;
        }
        fail(
          'Found the workspace root at ${dir.path} but no drift_storage '
          'package at packages/storage/drift_storage. If the package moved, '
          'update this test.',
        );
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'Could not locate the drift_storage package from '
    '${Directory.current.path}.',
  );
}

/// The result of walking one entry point's source closure.
typedef _Closure = ({
  /// Package-relative paths that name a VM-only library, and why.
  Map<String, Set<String>> offenders,

  /// Every package-relative file the walk actually read.
  Set<String> files,
});

/// Every `lib/`-local file reachable from [entryPoint] by import, export or
/// part, and which of them name a VM-only library.
_Closure _walk(String entryPoint) {
  final root = _packageRoot().path;
  final offenders = <String, Set<String>>{};
  final files = <String>{};
  final visited = <String>{};
  final queue = <String>['$root/lib/$entryPoint'];

  while (queue.isNotEmpty) {
    final path = _normalize(queue.removeLast());
    if (!visited.add(path)) continue;

    final file = File(path);
    if (!file.existsSync()) {
      // Codegen output is gitignored in this repo (`.gitignore`: `*.g.dart`,
      // `*.freezed.dart`) and regenerated by `melos run generate`, so a
      // missing generated part is an un-generated one, not a broken
      // reference: skipping keeps this test from depending on build_runner
      // having run. Once generation has run, those files ARE walked.
      //
      // Anything else missing is a real broken reference and fails here
      // rather than shrinking the closure silently.
      if (_isGenerated(path)) continue;
      fail(
        'Directive target does not exist: '
        '${path.substring(root.length + 1)} (referenced while walking '
        '$entryPoint). A missing non-generated file would shrink this '
        "check's closure without failing it.",
      );
    }

    final relative = path.substring(root.length + 1);
    files.add(relative);

    final source = file.readAsStringSync();
    for (final directive in _directive.allMatches(source)) {
      final text = directive.group(0)!;
      // `part of 'parent.dart';` points back up at a file already walked.
      if (RegExp(r'^[ \t]*part\s+of\b').hasMatch(text)) continue;

      for (final match in _directiveUri.allMatches(text)) {
        final uri = match.group(1) ?? match.group(2)!;
        final reason = _vmOnlyReason(uri);
        if (reason != null) {
          offenders.putIfAbsent(relative, () => <String>{}).add(reason);
          continue;
        }
        // A file may reach its own package by `package:` URI rather than
        // by relative path — including, dangerously, the native entry
        // point. Resolve those into `lib/` and keep walking, or a neutral
        // file could import drift_storage_native.dart and this check would
        // never look at what that pulls in.
        const ownPackage = 'package:drift_storage/';
        if (uri.startsWith(ownPackage)) {
          queue.add('$root/lib/${uri.substring(ownPackage.length)}');
          continue;
        }
        if (uri.startsWith('dart:') || uri.startsWith('package:')) {
          // Another package's own closure is not ours to police; what
          // matters is which libraries *this* package names.
          continue;
        }
        queue.add('${File(path).parent.path}/$uri');
      }
    }
  }

  return (offenders: offenders, files: files);
}

/// Whether [path] is build_runner/drift output, which is gitignored here and
/// may legitimately be absent before `melos run generate`.
bool _isGenerated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.endsWith('.steps.dart');

/// Collapses `a/b/../c` so the same file is not visited under two paths.
String _normalize(String path) {
  final segments = <String>[];
  for (final segment in path.split('/')) {
    if (segment == '.') continue;
    if (segment == '..' && segments.isNotEmpty && segments.last != '..') {
      segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

void main() {
  group('platform boundary (#287)', () {
    test('drift_storage.dart names no VM-only library', () {
      final closure = _walk('drift_storage.dart');

      // Guard against a vacuous pass: a mistyped entry point or a walk that
      // resolves nothing would leave `offenders` empty for the wrong reason.
      expect(
        closure.files,
        containsAll(<String>[
          'lib/drift_storage.dart',
          'lib/src/databases/server_database.dart',
          'lib/src/repositories/household_repository_impl.dart',
        ]),
        reason: 'the closure walk did not reach the files it exports',
      );

      expect(
        closure.offenders,
        isEmpty,
        reason:
            'The platform-neutral entry point must be importable from a web '
            'target. Anything needing dart:io, dart:ffi or a VM-only package '
            'belongs behind drift_storage_native.dart.',
      );
    });

    test('drift_storage_native.dart is where the native surface lives', () {
      // The complement of the check above: if the native entry point ever
      // stops carrying a native dependency, the split has collapsed and the
      // first test is passing for the wrong reason.
      expect(
        _walk('drift_storage_native.dart').offenders,
        isNotEmpty,
        reason:
            'drift_storage_native.dart exists to hold the dart:io / '
            'drift-native surface. An empty closure means the split is no '
            'longer doing anything.',
      );
    });

    test('a sibling library of a VM-only package is disqualifying too', () {
      // Pins the by-package matching rather than the by-URI matching this
      // check originally had: `sqlite3/sqlite3.dart` was listed and
      // `sqlite3/open.dart` was not, so a neutral file importing the latter
      // passed. Same for a VM-only library of an otherwise web-safe package.
      expect(_vmOnlyReason('package:sqlite3/open.dart'), isNotNull);
      // A drift library that is not on the web-safe list — including one
      // that does not exist today, so a future native `extensions/*` cannot
      // arrive pre-approved.
      expect(_vmOnlyReason('package:drift/native.dart'), isNotNull);
      expect(
        _vmOnlyReason('package:drift/extensions/moor_ffi.dart'),
        isNotNull,
      );
      expect(
        _vmOnlyReason('package:sqlite3_flutter_libs/open.dart'),
        isNotNull,
      );
      expect(_vmOnlyReason('package:drift/isolate.dart'), isNotNull);
      expect(_vmOnlyReason('dart:isolate'), isNotNull);

      // …while the web-safe libraries this package actually relies on stay
      // allowed, so the guard cannot pass by rejecting everything.
      expect(_vmOnlyReason('package:drift/drift.dart'), isNull);
      expect(_vmOnlyReason('package:drift/wasm.dart'), isNull);
      expect(_vmOnlyReason('package:flutter/foundation.dart'), isNull);
      expect(_vmOnlyReason('dart:async'), isNull);
    });
  });
}
