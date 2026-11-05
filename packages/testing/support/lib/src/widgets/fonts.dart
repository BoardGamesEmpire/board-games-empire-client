import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Loads the display typeface the titles are drawn in, so that a test
/// measures a title at the width a user's screen gives it (#710).
///
/// A widget test draws any family it doesn't have in its own test font, whose
/// letters are each a whole em wide. That is far wider than the display
/// face's, so a title that fits on a phone measures as cut: "Games" needs
/// 110dp in the test font and 71dp in its own. Call this from `setUpAll`
/// where a test asserts a title fits.
///
/// A loaded font stays for the rest of the test file, so every title in that
/// file is then measured in it. Keep such tests in a file of their own, so
/// the other tests of a screen don't change with it.
Future<void> loadDisplayFont() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final loader =
      FontLoader(
        'packages/${BgeTypography.displayFamilyPackage}/'
        '${BgeTypography.displayFamily}',
      )..addFont(
        rootBundle.load(
          'packages/${BgeTypography.displayFamilyPackage}/fonts/'
          'Fraunces-Variable.ttf',
        ),
      );
  await loader.load();
}
