import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Visual regression coverage for the four themes (#32).
///
/// Local check only — see the `test` job in `.github/workflows/ci.yaml`
/// for why goldens are excluded from CI (`--exclude-tags golden`):
/// Alchemist's CI goldens obscure text but still rasterize shapes and
/// anti-aliased edges per-platform, so a macOS-generated baseline does
/// not match a Linux CI render. Regenerate with
/// `flutter test --update-goldens` (or `melos run goldens:update`). Only
/// the CI variant (`goldens/ci/`) is committed; platform goldens are
/// gitignored. Tagged `golden` by alchemist.
void main() {
  // goldenTest returns Future<void>; the test framework tracks the
  // registration itself, so we intentionally don't await it here.
  unawaited(
    goldenTest(
      'BgeTheme renders the token showcase in all four themes',
      fileName: 'bge_theme_showcase',
      builder: () => GoldenTestGroup(
        scenarioConstraints: const BoxConstraints(maxWidth: 420),
        children: [
          GoldenTestScenario(
            name: 'light',
            child: _TokenShowcase(theme: BgeTheme.light()),
          ),
          GoldenTestScenario(
            name: 'dark',
            child: _TokenShowcase(theme: BgeTheme.dark()),
          ),
          GoldenTestScenario(
            name: 'high contrast light',
            child: _TokenShowcase(theme: BgeTheme.highContrastLight()),
          ),
          GoldenTestScenario(
            name: 'high contrast dark',
            child: _TokenShowcase(theme: BgeTheme.highContrastDark()),
          ),
        ],
      ),
    ),
  );
}

/// A deliberately static sampler of the roles the contrast guarantee
/// covers — no animations, no focus, no network.
class _TokenShowcase extends StatelessWidget {
  const _TokenShowcase({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final tokens = theme.extension<BgeTokens>()!;
    return Theme(
      data: theme,
      child: Material(
        color: scheme.surface,
        child: Padding(
          padding: EdgeInsets.all(tokens.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Title large', style: theme.textTheme.titleLarge),
              SizedBox(height: tokens.spaceSm),
              Text(
                'Body medium on surface.',
                style: theme.textTheme.bodyMedium,
              ),
              SizedBox(height: tokens.spaceMd),
              Row(
                children: [
                  FilledButton(onPressed: () {}, child: const Text('Filled')),
                  SizedBox(width: tokens.spaceSm),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('Outlined'),
                  ),
                ],
              ),
              SizedBox(height: tokens.spaceMd),
              _RolePair(
                label: 'primary container',
                background: scheme.primaryContainer,
                foreground: scheme.onPrimaryContainer,
                tokens: tokens,
              ),
              SizedBox(height: tokens.spaceSm),
              _RolePair(
                label: 'secondary container',
                background: scheme.secondaryContainer,
                foreground: scheme.onSecondaryContainer,
                tokens: tokens,
              ),
              SizedBox(height: tokens.spaceSm),
              // Ember and crimson are rendered ADJACENT on purpose. They are
              // the palette's one genuinely risky pair — both warm, both
              // mid-luminance — and the hue-separation test can only assert a
              // number. Side by side in a golden, a human can see at a glance
              // whether "attention" still reads as distinct from "failure".
              _RolePair(
                label: 'tertiary container (ember)',
                background: scheme.tertiaryContainer,
                foreground: scheme.onTertiaryContainer,
                tokens: tokens,
              ),
              SizedBox(height: tokens.spaceSm),
              _RolePair(
                label: 'error container',
                background: scheme.errorContainer,
                foreground: scheme.onErrorContainer,
                tokens: tokens,
              ),
              SizedBox(height: tokens.spaceMd),
              // Accents on the bare surface: how they actually appear as icons
              // and emphasis text, which the container swatches do not show.
              _AccentRow(scheme: scheme, tokens: tokens),
            ],
          ),
        ),
      ),
    );
  }
}

/// The four domain status colors, each with its mandatory icon.
///
/// Rendered on the bare surface because that is where status indicators
/// actually live. The icons are not decoration: the project conveys no meaning
/// by color alone, so a status swatch without its icon would misrepresent the
/// component this golden is meant to protect.
class _AccentRow extends StatelessWidget {
  const _AccentRow({required this.scheme, required this.tokens});

  final ColorScheme scheme;
  final BgeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final status = BgeStatusColors.forScheme(scheme);
    return Row(
      children: [
        for (final value in BgeStatus.values) ...[
          Icon(
            BgeStatusColors.iconFor(value),
            color: status.colorFor(value),
            size: tokens.spaceLg,
          ),
          SizedBox(width: tokens.spaceSm),
        ],
      ],
    );
  }
}

class _RolePair extends StatelessWidget {
  const _RolePair({
    required this.label,
    required this.background,
    required this.foreground,
    required this.tokens,
  });

  final String label;
  final Color background;
  final Color foreground;
  final BgeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spaceMd,
        vertical: tokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
      ),
      child: Text(label, style: TextStyle(color: foreground)),
    );
  }
}
