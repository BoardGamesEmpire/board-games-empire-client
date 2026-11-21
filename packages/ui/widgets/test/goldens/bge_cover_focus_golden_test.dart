import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:alchemist/alchemist.dart';
import 'package:bge_test_support/images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The cover's and the expansions badge's focus rings over a picture (#812).
///
/// Both rings lie on the cover's artwork, which can be any colour, so they
/// draw two tones 9:1 apart. The pixel checks in `bge_cover_tile_test.dart`
/// measure them in all four themes; these show what they look like, over a
/// picture filled with the theme's `primary`, which a one-tone `primary` ring
/// would vanish on, and over a mid grey, between light tones and dark.
///
/// A widget tree has one focus, so each ring and picture is a golden of its
/// own. The picture is a real image, one colour throughout, so the badge
/// keeps its own fill on it, as it does on a cover.
void main() {
  // goldenTest returns Future<void>; the framework tracks registration, so
  // these are intentionally not awaited.
  for (final (themeName, theme) in <(String, ThemeData)>[
    ('light', BgeTheme.light()),
    ('dark', BgeTheme.dark()),
  ]) {
    for (final (fillName, fill) in <(String, Color)>[
      ('primary', theme.colorScheme.primary),
      ('grey', _midGrey),
    ]) {
      for (final (ringName, label) in const [
        ('cover', _coverLabel),
        ('badge', _badgeLabel),
      ]) {
        unawaited(
          goldenTest(
            "The $ringName's focus ring over a $fillName picture in "
            '$themeName',
            fileName: 'bge_cover_focus_${themeName}_${ringName}_$fillName',
            pumpWidget: (tester, widget) =>
                _pumpServingPicture(tester, widget, fill),
            pumpBeforeTest: (tester) async {
              await _pumpUntilPictureDecoded(tester);
              await _focusControl(tester, label);
            },
            builder: () => GoldenTestScenario(
              name: '$ringName ring · $fillName picture',
              child: Theme(
                data: theme,
                child: Material(
                  color: theme.colorScheme.surface,
                  child: Padding(
                    padding: EdgeInsets.all(BgeTokens.standard.spaceMd),
                    child: BgeCoverTile(
                      label: _coverLabel,
                      imageUrl: _pictureUrl,
                      onTap: () {},
                      expansions: BgeCoverExpansions(
                        count: 2,
                        expanded: false,
                        onToggle: () {},
                        label: _badgeLabel,
                        showLabel: 'Show expansions',
                        hideLabel: 'Hide expansions',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
  }
}

const _pictureUrl = 'https://example.com/cover.png';

/// The cover's and the badge's accessible names, by which each is found.
const _coverLabel = 'Azul';
const _badgeLabel = 'Azul expansions, 2';

/// A mid grey, between light tones and dark, so neither of the ring's tones
/// wins by default.
const _midGrey = Color(0xFF777777);

/// Serves a picture filled with [fill], then pumps the scenario in.
///
/// The hook has to be set before the first pump: an `Image` that failed on
/// the test binding's 400 keeps its error. The picture is made here, outside
/// fake time, as encoding it needs real async work.
Future<void> _pumpServingPicture(
  WidgetTester tester,
  Widget widget,
  Color fill,
) async {
  final png = (await tester.runAsync(() => _solidPng(fill)))!;
  serveImages({_pictureUrl: png});
  try {
    await onlyPumpWidget(tester, widget);
  } on Object {
    // _pumpUntilPictureDecoded never runs, so its `finally` can't clear the
    // hook, and a hook still set would bury this error under the binding's.
    stopServingImages();
    rethrow;
  }
}

/// Pumps until the cover has decoded its picture, then stops serving. The
/// hook is cleared here, not in a `tearDown`: the binding checks for a set
/// hook before tearDowns run.
Future<void> _pumpUntilPictureDecoded(WidgetTester tester) async {
  try {
    await pumpUntilDecoded(tester, find.byType(BgeCoverTile));
  } finally {
    stopServingImages();
  }
}

/// Gives focus to the control named [label], the cover or its badge, with
/// the highlight mode the keyboard's, so its ring shows.
///
/// Focus is requested rather than tabbed to: under the golden host a Tab
/// moves nothing. The ring reads the same state either way: focus, the
/// keyboard's highlight mode, and no mouse press since the last key.
Future<void> _focusControl(WidgetTester tester, String label) async {
  final strategy = FocusManager.instance.highlightStrategy;
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  addTearDown(() => FocusManager.instance.highlightStrategy = strategy);

  final semantics = tester.ensureSemantics();
  try {
    // The name sits above the control's ink, and the ink's focus node above
    // everything the ink builds, so its deepest element finds it.
    final ink = find
        .descendant(
          of: find.bySemanticsLabel(label),
          matching: find.byType(InkWell),
        )
        .first;
    final inside = find
        .descendant(of: ink, matching: find.byWidgetPredicate((_) => true))
        .last;
    Focus.of(tester.element(inside)).requestFocus();
  } finally {
    semantics.dispose();
  }
  await tester.pumpAndSettle();
}

/// A 60 x 60 PNG filled with [fill].
Future<Uint8List> _solidPng(Color fill) async {
  const side = 60;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..color = fill,
  );
  final image = await recorder.endRecording().toImage(side, side);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
