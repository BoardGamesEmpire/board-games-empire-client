import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
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
/// Local-only, like the token goldens — see `bge_theme_golden_test.dart` and
/// `flutter_test_config.dart` for why platform variants are disabled (#159).
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
        // `pumpOnce`, not the default pump-and-settle. The in-flight submit
        // button contains an indeterminate `CircularProgressIndicator`, which
        // never stops animating — pumping until settled simply times out.
        // One frame is also what makes the spinner's rotation deterministic
        // rather than dependent on how long the run took.
        pumpBeforeTest: pumpOnce,
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
            ],
          ],
        ),
      ),
    );
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
