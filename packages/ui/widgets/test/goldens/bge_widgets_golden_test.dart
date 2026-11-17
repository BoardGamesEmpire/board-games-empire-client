import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:bge_test_support/images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Visual regression coverage for the shared widget set (#165).
///
/// Two axes, both of which have already caught real defects in this codebase:
///
/// - **Theme** — light and dark. The palette is authored dark-first and light
///   derived, so a change that looks right in one can regress the other.
/// - **Text scale** — 1.0 and 2.0. The app guarantees 200% (WCAG 1.4.4), and
///   that is where layouts actually break: #163's in-flight button overflowed
///   by 298px at 2.0, and the home drawer label went 2.4px over when the type
///   scale gained letter-spacing.
///
/// The widget tests beside these assert *no exception* at large scale, which
/// catches breakage. These catch the quieter failure the exception does not:
/// text that fits but is unreadably cramped, an ellipsis that eats the whole
/// label, a banner whose icon no longer aligns with its first line.
///
/// Rendered in the golden container, like the token goldens — see
/// `bge_theme_golden_test.dart` for why, and `flutter_test_config.dart` for
/// why platform variants are disabled (#159).
void main() {
  // goldenTest returns Future<void>; the framework tracks registration, so
  // these are intentionally not awaited.
  for (final (themeName, theme) in <(String, ThemeData)>[
    ('light', _light),
    ('dark', _dark),
  ]) {
    unawaited(
      goldenTest(
        'Bge widgets render in $themeName at 1.0 and 2.0 text scale',
        fileName: 'bge_widgets_$themeName',
        // Zero-duration pumps, not the default pump-and-settle. The in-flight
        // submit button contains an indeterminate `CircularProgressIndicator`,
        // which never stops animating — pumping until settled simply times
        // out. Zero-duration pumps never advance the fake clock, and
        // `runAsync` does not either, so the spinner's rotation is
        // deterministic rather than dependent on how long the run took.
        pumpWidget: _pumpServingCovers,
        pumpBeforeTest: _pumpUntilCoversDecoded,
        builder: () => GoldenTestGroup(
          columns: 2,
          scenarioConstraints: const BoxConstraints(maxWidth: 320),
          children: [
            for (final scale in const [1.0, 2.0]) ...[
              GoldenTestScenario(
                name: 'submit button · resting · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  child: const BgeSubmitButton(
                    label: 'Create household',
                    onPressed: _noop,
                  ),
                ),
              ),
              GoldenTestScenario(
                name: 'submit button · in flight · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  // The #163 case: 320dp at 2.0 is where the hand-rolled
                  // version overflowed.
                  child: const BgeSubmitButton(
                    label: 'Add server',
                    progressLabel: 'Contacting server…',
                    submitting: true,
                    onPressed: null,
                  ),
                ),
              ),
              GoldenTestScenario(
                name: 'banner · error · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  child: const BgeInlineBanner(
                    tone: BgeBannerTone.error,
                    title: 'Could not add server',
                    message: 'That URL is not a BGE server.',
                  ),
                ),
              ),
              GoldenTestScenario(
                // Rendered next to the error banner on purpose: ember and
                // crimson are the palette's one genuinely confusable pair, and
                // the hue-separation test can only assert a number.
                name: 'banner · warning · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  child: const BgeInlineBanner(
                    tone: BgeBannerTone.warning,
                    title: 'Sync is behind',
                    message: 'Two changes are waiting to upload.',
                  ),
                ),
              ),
              GoldenTestScenario(
                name: 'state · loading · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  child: const Center(
                    child: BgeLoadingState(label: 'Loading your events'),
                  ),
                ),
              ),
              GoldenTestScenario(
                name: 'state · empty · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  child: const BgeEmptyState(
                    icon: Icons.event_busy_outlined,
                    title: 'No upcoming events',
                    body: 'Plan one, or wait for an invitation.',
                    action: FilledButton(
                      onPressed: _noop,
                      child: Text('Plan an event'),
                    ),
                  ),
                ),
              ),
              GoldenTestScenario(
                // Initials, the no-name icon, and a picture that failed (the
                // test binding answers every image request with an error).
                name: 'avatar · initials, icon, failed image · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: BgeTokens.standard.spaceSm,
                    children: const [
                      BgeAvatar(initials: 'AB'),
                      BgeAvatar(initials: null),
                      BgeAvatar(
                        initials: 'WW',
                        imageUrl: 'https://example.com/missing.png',
                      ),
                    ],
                  ),
                ),
              ),
              GoldenTestScenario(
                // A real portrait and a real landscape image, banded so the
                // top shows: the square crop keeps the top band, and whole
                // draws everything, top-aligned, with no bars (#937).
                name: 'thumbnail · cover crop and whole · ${scale}x',
                child: _Host(
                  theme: theme,
                  scale: scale,
                  child: Wrap(
                    spacing: BgeTokens.standard.spaceSm,
                    runSpacing: BgeTokens.standard.spaceSm,
                    children: [
                      for (final url in [_portraitUrl, _landscapeUrl]) ...[
                        BgeThumbnail(url: url),
                        BgeThumbnail(url: url, whole: true),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const _portraitUrl = 'https://example.com/portrait.png';
const _landscapeUrl = 'https://example.com/landscape.png';

/// Serves the two banded cover images, then pumps the scenarios in.
///
/// The hook has to be set before the first pump: an `Image` that failed on
/// the test binding's 400 keeps its error, so serving afterwards is too
/// late. The images are made here, outside fake time, as they need real
/// async work.
Future<void> _pumpServingCovers(WidgetTester tester, Widget widget) async {
  final portrait = (await tester.runAsync(() => bandedPng(60, 100)))!;
  final landscape = (await tester.runAsync(() => bandedPng(100, 60)))!;
  serveImages({_portraitUrl: portrait, _landscapeUrl: landscape});
  try {
    await onlyPumpWidget(tester, widget);
  } on Object {
    // _pumpUntilCoversDecoded never runs, so its `finally` can't clear the
    // hook, and a hook still set would bury this error under the binding's.
    stopServingImages();
    rethrow;
  }
}

/// Pumps until every thumbnail has decoded its image, then stops serving.
///
/// The load and the decode run outside fake time, so each attempt lets real
/// time pass first. The hook is cleared here, not in a `tearDown`: the
/// binding checks for a set hook before tearDowns run. The images stay in
/// the widgets.
Future<void> _pumpUntilCoversDecoded(WidgetTester tester) async {
  final thumbnails = find.byType(BgeThumbnail);
  final decoded = find.descendant(
    of: thumbnails,
    matching: find.byType(RawImage),
  );
  try {
    for (var i = 0; i < 20; i++) {
      await pumpOnce(tester);
      if (decoded.evaluate().length == thumbnails.evaluate().length) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(
      decoded,
      findsNWidgets(thumbnails.evaluate().length),
      reason: 'covers did not decode',
    );
  } finally {
    stopServingImages();
  }
}

void _noop() {}

final ThemeData _light = BgeTheme.light();
final ThemeData _dark = BgeTheme.dark();

/// Themed, text-scaled host. Deliberately not `BgePage`: these scenarios
/// exercise the widgets, and a full-page scaffold would dominate the frame.
class _Host extends StatelessWidget {
  const _Host({required this.theme, required this.scale, required this.child});

  final ThemeData theme;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Theme(
        data: theme,
        child: Material(
          color: theme.colorScheme.surface,
          child: Padding(
            padding: EdgeInsets.all(BgeTokens.standard.spaceMd),
            child: child,
          ),
        ),
      ),
    );
  }
}
