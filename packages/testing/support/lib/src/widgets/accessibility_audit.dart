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

/// Declares one `testWidgets` per [kAuditViewports] × [kAuditThemes] cell
/// (#50). Exactly one of [build] and [pump] is given; otherwise it throws an
/// ArgumentError when the group is declared.
///
/// Each test is named `<description> — <label>, <theme>`. It sets the view
/// size ([useViewSize]) and the cell's text scale, holds semantics, pumps
/// `build(theme)` or calls `pump(tester, theme)`, runs [arrange], settles,
/// checks that the screen drew at the cell's text scale and in its theme, and
/// then runs [expectMeetsAccessibilityGuidelines].
///
/// The cell applies the text scale, on the test's platform dispatcher, so
/// that it reaches the screen the way a device's setting does (#767). A
/// harness applies only the theme it is given, and overrides no text scale of
/// its own: a cell whose screen was not drawn at its scale, or not in its
/// theme, fails and says which. Use [pump] for a harness that needs the
/// tester, to pump and wait for a state the screen starts in; [arrange] then
/// keeps only what reaches the state the cell audits.
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
  Widget Function(ThemeData theme)? build,
  Future<void> Function(WidgetTester tester, ThemeData theme)? pump,
  Future<void> Function(WidgetTester tester)? arrange,
  bool textContrast = true,
  bool settle = true,
  Object? skip,
}) {
  // Before group(), which inside a running test throws a StateError of its
  // own.
  if ((build == null) == (pump == null)) {
    throw ArgumentError(
      'Give auditScreen exactly one of build and pump: '
      '${build == null ? 'neither was' : 'both were'} given.',
    );
  }
  final pumpCell = pump ?? (tester, theme) => tester.pumpWidget(build!(theme));
  group(description, skip: skip, () {
    for (final viewport in kAuditViewports) {
      for (final MapEntry(key: themeName, value: theme)
          in kAuditThemes.entries) {
        testWidgets(
          '— ${viewport.label}, $themeName',
          (tester) => runAuditCell(
            tester,
            viewport,
            theme(),
            pump: pumpCell,
            arrange: arrange,
            textContrast: textContrast,
            settle: settle,
          ),
        );
      }
    }
  });
}

/// One [auditScreen] cell: [pump]s the screen in [theme] at [viewport], runs
/// [arrange], settles, and audits it (#50, #767).
///
/// Not exported from `widgets.dart`: suites declare cells with [auditScreen].
/// The package's own test calls it to watch a cell fail, which a declared
/// cell can only do as a red test.
Future<void> runAuditCell(
  WidgetTester tester,
  AuditViewport viewport,
  ThemeData theme, {
  required Future<void> Function(WidgetTester tester, ThemeData theme) pump,
  Future<void> Function(WidgetTester tester)? arrange,
  bool textContrast = true,
  bool settle = true,
}) async {
  useViewSize(tester, viewport.size);
  // The binding doesn't reset it between tests, so the teardown does.
  tester.platformDispatcher.textScaleFactorTestValue = viewport.textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  // Disposed in the body, not a teardown: the framework verifies semantics
  // handles before teardowns run.
  final handle = tester.ensureSemantics();
  try {
    await pump(tester, theme);
    await arrange?.call(tester);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(_unsettledPump);
    }

    _expectDrawnAtCell(viewport, theme);
    await expectMeetsAccessibilityGuidelines(
      tester,
      textContrast: textContrast,
    );
  } finally {
    handle.dispose();
  }
}

/// Fails unless the screen was drawn at [viewport]'s text scale and in
/// [theme]'s colour scheme (#767): a harness that sets its own scale or theme
/// would otherwise audit a cell other than the one its test is named for.
///
/// Every `Scaffold` must sit under both, so a harness that overrides them for
/// one route, or for the page around a pop-up, fails. Below a scaffold, text
/// is not held to the scale one by one: Flutter's own widgets clamp it (an
/// `AppBar` title, a `NavigationBar` label, a `CircleAvatar`), so at least one
/// piece of text or spinner on screen must be drawn at it, and that is what
/// a screen with no scaffold is held to too.
///
/// Reads the `MediaQuery` and `Theme` each piece sits under, not
/// `RichText.textScaler`: an `Icon` draws its glyph with its own
/// `TextScaler.noScaling`. A spinner counts as drawn too, for a loading state
/// whose label is announced and not drawn. The theme is matched on its colour
/// scheme, so a harness that swaps in `ThemeData.dark()` for the cell's
/// `BgeTheme.dark()` fails as well as one in the other brightness.
void _expectDrawnAtCell(AuditViewport viewport, ThemeData theme) {
  final drawn = find
      .byWidgetPredicate((w) => w is RichText || w is ProgressIndicator)
      .evaluate()
      .toList();
  if (drawn.isEmpty) {
    fail(
      "There is nothing drawn to check the cell's scale and theme on: no text "
      'or spinner is on screen.',
    );
  }
  final roots = find.byType(Scaffold).evaluate().toList();

  bool atScale(Element e) =>
      MediaQuery.textScalerOf(e).scale(10) == 10 * viewport.textScale;
  bool inTheme(Element e) => Theme.of(e).colorScheme == theme.colorScheme;
  bool atCell(Element e) => atScale(e) && inTheme(e);
  if (roots.every(atCell) && drawn.any(atCell)) return;

  final scaled = roots.every(atScale) && drawn.any(atScale);
  final themed = roots.every(inTheme) && drawn.any(inTheme);
  // Where the scale is off: the scaffolds that are, else everything drawn.
  final offRoots = roots.where((e) => !atScale(e));
  final scales = {
    for (final e in offRoots.isEmpty ? drawn : offRoots)
      MediaQuery.textScalerOf(e).scale(10) / 10,
  }.join(', ');
  final scale = viewport.textScale;
  final brightness = theme.brightness.name;
  final noScale =
      "the harness overrides the cell's text scale: the screen is drawn at "
      '$scales, not $scale';
  final noTheme =
      "the harness overrides the cell's theme: the screen is not drawn in the "
      "cell's $brightness colour scheme";
  final neverBoth =
      "the harness overrides the cell's text scale or theme: nothing is "
      "drawn at $scale in the cell's $brightness colour scheme";
  final missing = [
    if (!scaled) noScale,
    if (!themed) noTheme,
    if (scaled && themed) neverBoth,
  ];
  fail(
    'The screen did not draw at the cell it is audited for; '
    '${missing.join('; and ')}. A harness applies only the theme it is '
    'given, and the cell sets the scale (#767).',
  );
}
