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
  });
}
