// The web counterpart of `drift_storage`'s platform-boundary guard (#288).
//
// This package is browser-only, and its whole reason to exist is that the
// shared repositories can run there. A single `dart:io` import — or one
// import of `drift_storage_native.dart` — silently breaks a web build, and
// the compiler only says so at `flutter build web` time, after the import is
// already on master.
//
// So: walk the transitive source closure of the entry point and fail on the
// file that named something a browser does not have. Source-level on
// purpose, like its sibling — it reads this package's own `lib/` and does not
// resolve into other packages, because what matters is which libraries *this*
// package names.
//
// ## Why this is a second copy of the walker
//
// It is a deliberate duplicate of the machinery in
// `packages/storage/drift_storage/test/platform_boundary_test.dart`, and the
// duplication is the cheaper option at two call sites: the two guards differ
// in direction (that one proves a *native* half stays native; this one has no
// native half at all), in entry points, and in three of the four
// classification tables. Extracting a shared walker would mean a new test
// package that both storage packages depend on, to remove ~100 lines from one
// of them.
//
// If a third guard appears, extract it — do not make a third copy.
//
// ## The sqlite3 carve-out this file owns (#288, from #294)
//
// `drift_storage`'s guard treats **all** of `package:sqlite3` as VM-only,
// deliberately: its platform-neutral half must never touch sqlite3 at all.
// That left the genuinely web-safe libraries in that package —
// `wasm.dart` and `common.dart` — with nowhere to be recorded as such. This
// is that place. Verified against sqlite3 3.5.2 by walking both closures:
// 43 files from `wasm.dart` and 35 from `common.dart`, none of which name
// `dart:io`, `dart:ffi` or `dart:isolate`. `sqlite3.dart` does (`dart:ffi`,
// via `src/ffi/`), which is why the package cannot simply be allow-listed
// whole.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `dart:` libraries that do not exist on web.
///
/// `dart:js_interop` and `package:web` are the *opposite* case and are
/// deliberately absent: this package is expected to reach them (through
/// `package:drift/wasm.dart`), and a VM build being unable to compile it is
/// the intended state, not a violation.
const _vmOnlyDartLibraries = {
  'dart:io',
  'dart:ffi',
  'dart:isolate',
  'dart:mirrors',
  'dart:cli',
};

/// Packages with no web implementation at all: every library in them is
/// disqualifying. Matched by package rather than by exact URI so a sibling
/// library cannot slip through.
const _vmOnlyPackages = {
  'sqlite3_flutter_libs',
  'path_provider',
  'path_provider_foundation',
  'path_provider_android',
  // `path_provider_linux` (2.2.2) unconditionally exports a file importing
  // `dart:io`; `path_provider_windows` exports behind `if (dart.library.ffi)`
  // and is correctly absent here (#294).
  'path_provider_linux',
};

/// Packages shipping *both* web-safe and VM-only libraries, listed as the set
/// of libraries that ARE web-safe. Anything else in these packages counts as
/// VM-only: a deny-list would silently miss a native library added upstream,
/// while a false positive here is one line to fix, with the offending file
/// named in the failure.
const _webSafeLibrariesByPackage = {
  // Mirrors the allow-list in `drift_storage`'s guard, which #294 completed
  // and verified against drift; re-verified against 2.34.3, whose library
  // set is identical. `wasm.dart` matters most here: it is this package's
  // whole point.
  'drift': {
    'drift.dart',
    'wasm.dart',
    'web.dart',
    'remote.dart',
    'backends.dart',
    'extensions/json1.dart',
    'extensions/native.dart',
    'extensions/geopoly.dart',
    'sqlite_keywords.dart',
    'internal/versioned_schema.dart',
    'internal/migrations.dart',
    'internal/modular.dart',
    // NOT 'internal/export_schema.dart': imports `dart:isolate` directly.
  },
  // The carve-out described in the header — see #294's correction.
  'sqlite3': {'wasm.dart', 'common.dart'},
  // The #287 split, from the other side: this package may import the
  // platform-neutral entry point and MUST NOT import the native one, which
  // carries the `dart:io` / `drift/native.dart` surface. This single line is
  // what keeps the split honest on the web side.
  'drift_storage': {'drift_storage.dart'},
};

/// Whole `import`/`export`/`part` directives, keyword through `;`, so a
/// directive wrapped across lines by `dart format` is still one match.
final _directive = RegExp(
  r'^[ \t]*(?:import|export|part)\b[^;]*;',
  multiLine: true,
);

/// Every quoted URI inside one directive — a conditional import names more
/// than one, and reading only the first would leave a branch unexamined.
final _directiveUri = RegExp(r'''\'([^\']+)\'|"([^"]+)"''');

/// Why [uri] cannot appear in this package's closure, or null if it can.
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

/// This package's root, located by reading pubspecs rather than by assuming
/// the working directory: `flutter test` inside the package and
/// `flutter test <path>` from the workspace root have different cwds.
Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      final contents = pubspec.readAsStringSync();
      if (contents.contains('name: web_storage')) return dir;
      if (contents.contains('\nworkspace:')) {
        final package = Directory('${dir.path}/packages/storage/web_storage');
        final packagePubspec = File('${package.path}/pubspec.yaml');
        if (packagePubspec.existsSync() &&
            packagePubspec.readAsStringSync().contains('name: web_storage')) {
          return package;
        }
        fail(
          'Found the workspace root at ${dir.path} but no web_storage package '
          'at packages/storage/web_storage. If the package moved, update this '
          'test.',
        );
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'Could not locate the web_storage package from '
    '${Directory.current.path}.',
  );
}

/// The result of walking one entry point's source closure.
typedef _Closure = ({
  /// Package-relative paths that name a non-web-safe library, and why.
  Map<String, Set<String>> offenders,

  /// Every package-relative file the walk actually read.
  Set<String> files,
});

/// Every `lib/`-local file reachable from [entryPoint] by import, export or
/// part, and which of them name something a browser does not have.
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
      // Generated output is gitignored in this repo and regenerated by
      // `melos run generate`, so a missing generated part is an un-generated
      // one rather than a broken reference. Anything else missing would
      // shrink this check's closure without failing it, so it fails here.
      if (_isGenerated(path)) continue;
      fail(
        'Directive target does not exist: '
        '${path.substring(root.length + 1)} (referenced while walking '
        '$entryPoint).',
      );
    }

    final relative = path.substring(root.length + 1);
    files.add(relative);

    final source = file.readAsStringSync();
    for (final directive in _directive.allMatches(source)) {
      final text = directive.group(0)!;
      if (RegExp(r'^[ \t]*part\s+of\b').hasMatch(text)) continue;

      for (final match in _directiveUri.allMatches(text)) {
        final uri = match.group(1) ?? match.group(2)!;
        final reason = _vmOnlyReason(uri);
        if (reason != null) {
          offenders.putIfAbsent(relative, () => <String>{}).add(reason);
          continue;
        }
        // A file may reach its own package by `package:` URI rather than by
        // relative path; resolve those into `lib/` and keep walking.
        const ownPackage = 'package:web_storage/';
        if (uri.startsWith(ownPackage)) {
          queue.add('$root/lib/${uri.substring(ownPackage.length)}');
          continue;
        }
        if (uri.startsWith('dart:') || uri.startsWith('package:')) {
          // Another package's own closure is not ours to police.
          continue;
        }
        queue.add('${File(path).parent.path}/$uri');
      }
    }
  }

  return (offenders: offenders, files: files);
}

/// Whether [path] is build_runner/drift output, gitignored here and possibly
/// absent before `melos run generate`.
bool _isGenerated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.endsWith('.steps.dart');

/// Collapses `a/b/../c` so one file is not visited under two paths.
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
  group('platform boundary (#288)', () {
    test('web_storage.dart names nothing a browser lacks', () {
      final closure = _walk('web_storage.dart');

      // Guard against a vacuous pass: a mistyped entry point, or a walk that
      // resolved nothing, would leave `offenders` empty for the wrong reason.
      expect(
        closure.files,
        containsAll(<String>[
          'lib/web_storage.dart',
          'lib/src/databases/wasm_executor_factory.dart',
          'lib/src/databases/web_storage_persistence.dart',
          'lib/src/composition/web_storage_installer.dart',
        ]),
        reason: 'the closure walk did not reach the files it exports',
      );

      expect(
        closure.offenders,
        isEmpty,
        reason:
            'This package is browser-only: every library it names must exist '
            'on web. A dart:io dependency does not belong on this side of the '
            '#287 split at all.',
      );
    });

    test(
      'the executor really does reach drift/wasm — otherwise the check above '
      'is guarding an empty boundary',
      () {
        final source = File(
          '${_packageRoot().path}/lib/src/databases/wasm_executor_factory.dart',
        ).readAsStringSync();

        expect(source, contains("import 'package:drift/wasm.dart';"));
      },
    );

    test('sqlite3 is carved up here, not treated wholesale (#294)', () {
      // The two libraries `drift_storage`'s guard deliberately refuses, and
      // which this package is the right home for. Asserted directly rather
      // than through the closure because nothing in `lib/` imports sqlite3
      // today — `WasmDatabase.open` handles the module itself. The
      // classification is pinned now so a future executor that DOES need
      // `wasm.dart` (a custom VFS, an sqlite3mc build) is not blocked by a
      // guard that was never taught the difference.
      expect(_vmOnlyReason('package:sqlite3/wasm.dart'), isNull);
      expect(_vmOnlyReason('package:sqlite3/common.dart'), isNull);

      // …while the rest of the package stays disqualifying: `sqlite3.dart`
      // reaches `dart:ffi` through `src/ffi/`, and a name the allow-list has
      // never heard of is refused rather than assumed safe (`open.dart` was
      // removed upstream; a future addition gets the same treatment).
      expect(_vmOnlyReason('package:sqlite3/sqlite3.dart'), isNotNull);
      expect(_vmOnlyReason('package:sqlite3/open.dart'), isNotNull);
    });

    test('the native half of the #287 split is out of bounds', () {
      // The single most likely way to break a web build from this package:
      // importing the barrel that carries `dart:io` and
      // `package:drift/native.dart`.
      expect(
        _vmOnlyReason('package:drift_storage/drift_storage_native.dart'),
        isNotNull,
      );
      expect(_vmOnlyReason('package:drift_storage/drift_storage.dart'), isNull);
    });

    test('the usual VM-only suspects are still refused', () {
      expect(_vmOnlyReason('dart:io'), isNotNull);
      expect(_vmOnlyReason('dart:ffi'), isNotNull);
      expect(_vmOnlyReason('dart:isolate'), isNotNull);
      expect(_vmOnlyReason('package:drift/native.dart'), isNotNull);
      expect(_vmOnlyReason('package:drift/isolate.dart'), isNotNull);
      expect(
        _vmOnlyReason('package:drift/internal/export_schema.dart'),
        isNotNull,
      );
      expect(
        _vmOnlyReason('package:path_provider/path_provider.dart'),
        isNotNull,
      );

      // …and the web-safe libraries this package relies on stay allowed, so
      // the guard cannot pass by rejecting everything.
      expect(_vmOnlyReason('package:drift/drift.dart'), isNull);
      expect(_vmOnlyReason('package:drift/wasm.dart'), isNull);
      expect(_vmOnlyReason('package:flutter/foundation.dart'), isNull);
      expect(_vmOnlyReason('package:models/domain.dart'), isNull);
      expect(_vmOnlyReason('dart:async'), isNull);
    });
  });
}
