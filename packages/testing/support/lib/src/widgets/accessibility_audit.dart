import 'package:bge_test_support/src/widgets/viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One cell of #50's audit matrix: a render surface and the text scale a
/// screen is drawn at.
class AuditViewport {
  /// A [size] drawn at [textScale], called [label] in test names.
  const AuditViewport(this.size, this.textScale, this.label);

  /// The render surface, in logical pixels.
  final Size size;

  /// The text scale factor the screen is built with.
  final double textScale;

  /// Reads in a test name, e.g. `320dp × 2.0`.
  final String label;
}

/// The two viewports every screen is audited at (#50): the narrowest supported
/// width at the largest text scale, and a common phone at the default scale.
const List<AuditViewport> kAuditViewports = [
  AuditViewport(Size(320, 800), 2, '320dp × 2.0'),
  AuditViewport(Size(390, 844), 1, '390dp × 1.0'),
];

/// The themes every screen is audited in (#50), keyed by the name that ends a
/// test's title.
const Map<String, ThemeData Function()> kAuditThemes = {
  'light': BgeTheme.light,
  'dark': BgeTheme.dark,
};

/// Runs Flutter's accessibility guidelines on what is pumped now (#50):
/// the 48dp tap-target size (iOS's 44pt bar is under it, so it is not run), a
/// label on every tappable, and, unless [textContrast] is false, text
/// contrast.
///
/// The caller holds `tester.ensureSemantics()`; without it there is no
/// semantics tree and the guidelines have nothing to check.
///
/// Text contrast is measured in the test font (Ahem), which draws solid
/// blocks; that is the mode #50 settled on, so no fonts are loaded here.
Future<void> expectMeetsAccessibilityGuidelines(
  WidgetTester tester, {
  bool textContrast = true,
}) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  if (textContrast) {
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }
}

/// Long enough to finish a route or entrance transition when a state cannot
/// settle (#50).
const _unsettledPump = Duration(seconds: 1);

/// Declares one `testWidgets` per [kAuditViewports] x [kAuditThemes] cell,
/// named `<description> — <label>, <theme>` (#50).
///
/// Each sets the view size ([useViewSize]), holds semantics, pumps
/// `build(theme, TextScaler.linear(scale))`, runs [arrange], settles, and then
/// runs [expectMeetsAccessibilityGuidelines].
///
/// Pass `settle: false` for a state that never settles, such as a loading or
/// busy state spinning an indeterminate `CircularProgressIndicator`, where
/// `pumpAndSettle` would time out. The test then pumps one frame and a fixed
/// second instead, enough to finish an entrance or route transition.
///
/// The four tests sit in a `group` so that [skip] can be a String reason
/// (`skip: 'see #NNN'`), which `testWidgets` itself, taking a `bool?`,
/// cannot carry to the runner.
@isTestGroup
void auditScreen(
  String description, {
  required Widget Function(ThemeData theme, TextScaler textScaler) build,
  Future<void> Function(WidgetTester tester)? arrange,
  bool textContrast = true,
  bool settle = true,
  Object? skip,
}) {
  group(description, skip: skip, () {
    for (final viewport in kAuditViewports) {
      for (final MapEntry(key: themeName, value: theme)
          in kAuditThemes.entries) {
        testWidgets('— ${viewport.label}, $themeName', (tester) async {
          useViewSize(tester, viewport.size);
          // Disposed in the body, not a teardown: the framework verifies
          // semantics handles before teardowns run.
          final handle = tester.ensureSemantics();
          try {
            await tester.pumpWidget(
              build(theme(), TextScaler.linear(viewport.textScale)),
            );
            await arrange?.call(tester);
            if (settle) {
              await tester.pumpAndSettle();
            } else {
              await tester.pump();
              await tester.pump(_unsettledPump);
            }

            await expectMeetsAccessibilityGuidelines(
              tester,
              textContrast: textContrast,
            );
          } finally {
            handle.dispose();
          }
        });
      }
    }
  });
}
