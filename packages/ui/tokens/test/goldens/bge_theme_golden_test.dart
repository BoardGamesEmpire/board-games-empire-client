import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Visual regression coverage for the four themes (#32).
///
/// Regenerate with `flutter test --update-goldens`. Only the CI variant
/// (`goldens/ci/`, Ahem-rendered, renderer-stable) is committed; platform
/// goldens are gitignored human-review artifacts. Tagged `golden` by
/// alchemist — `flutter test --exclude-tags golden` skips.
void main() {
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
                label: 'error container',
                background: scheme.errorContainer,
                foreground: scheme.onErrorContainer,
                tokens: tokens,
              ),
            ],
          ),
        ),
      ),
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
