import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the SIL OFL obligation for the bundled Fraunces font (#32).
///
/// OFL 1.1 requires the notice to be **distributed with** the font. Flutter
/// satisfies that by folding each package's root `LICENSE` into the app's
/// aggregated license asset — the one `showLicensePage` reads. Two things
/// follow, and neither is obvious:
///
///   * `fonts/OFL.txt` does NOT ship. It is not at the package root and asset
///     declarations do not feed the license collector, so for a while the
///     pubspec claimed the notice shipped when nothing was carrying it.
///   * Deleting `LICENSE` breaks the licence terms silently. Nothing else in
///     the build would complain.
void main() {
  final packageRoot = Directory.current.path;

  group('bundled font licensing', () {
    test('the font asset is present', () {
      expect(
        File('$packageRoot/fonts/Fraunces-Variable.ttf').existsSync(),
        isTrue,
      );
    });

    test('the OFL notice sits where Flutter will collect it', () {
      final license = File('$packageRoot/LICENSE');
      expect(
        license.existsSync(),
        isTrue,
        reason:
            'packages/ui/tokens/LICENSE is what reaches a release build. '
            'fonts/OFL.txt alone does not ship.',
      );

      final text = license.readAsStringSync();
      expect(text, contains('SIL Open Font License'));
      expect(text, contains('Fraunces'));
      expect(
        text,
        contains('Copyright'),
        reason: 'OFL 1.1 requires the copyright notice, not just the terms',
      );
    });

    test('the package license does not misrepresent the Dart source', () {
      // Flutter attributes a package-root LICENSE to the PACKAGE. A file
      // holding only the font's OFL would therefore present `ui_tokens`
      // itself as OFL-licensed and drop the Apache-2.0 terms the source is
      // actually under. Both entries ship, in Flutter's documented
      // multi-entry format: names, blank line, text, 80 hyphens between.
      final text = File('$packageRoot/LICENSE').readAsStringSync();

      // The bare "ui_tokens" on line 1 looks like a stray word and has been
      // deleted once already. It is load-bearing. Because this file holds TWO
      // licenses, Flutter's collector treats everything before the first blank
      // line of EACH entry as the list of package names that entry applies to
      // (LicenseCollector.obtainLicenses). Without it, the Apache entry's
      // first three lines become the "package names", and the app's license
      // page lists:
      //
      //     Apache License
      //     Version 2.0, January 2004
      //     http://www.apache.org/licenses/
      //
      // as three packages instead of `ui_tokens`. Keep the line.
      expect(
        text,
        startsWith('ui_tokens\n\n'),
        reason:
            'the first entry must be introduced by its package name followed '
            'by a blank line, or Flutter parses the license text itself as '
            'the package list',
      );
      expect(text, contains('Apache License'));
      expect(
        text,
        contains('\n${'-' * 80}\nFraunces\n'),
        reason:
            'the two licenses must be separated by the 80-hyphen delimiter '
            'Flutter uses to split entries, or they merge into one',
      );
    });
  });
}
