import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:ui_tokens/ui_tokens.dart';

/// The keyboard focus ring on each button type (#644), at 390dp and 1.0
/// text: `focusRingGap` outside the shape on the filled, tonal and icon
/// buttons, and inside the edge on the text, outlined and elevated ones.
///
/// Each golden shows the same button twice, with keyboard focus and at
/// rest, so the ring reads against the button without it. Rendered in the
/// golden container, like `bge_theme_golden_test.dart`: see there for why.
void main() {
  final buttons = <String, Widget Function({required bool autofocus})>{
    'filled': ({required autofocus}) => FilledButton(
      autofocus: autofocus,
      onPressed: () {},
      child: const Text('Go'),
    ),
    'tonal': ({required autofocus}) => FilledButton.tonal(
      autofocus: autofocus,
      onPressed: () {},
      child: const Text('Go'),
    ),
    'icon': ({required autofocus}) => IconButton(
      autofocus: autofocus,
      onPressed: () {},
      icon: const Icon(Icons.add),
    ),
    'outlined': ({required autofocus}) => OutlinedButton(
      autofocus: autofocus,
      onPressed: () {},
      child: const Text('Go'),
    ),
    'text': ({required autofocus}) => TextButton(
      autofocus: autofocus,
      onPressed: () {},
      child: const Text('Go'),
    ),
    'elevated': ({required autofocus}) => ElevatedButton(
      autofocus: autofocus,
      onPressed: () {},
      child: const Text('Go'),
    ),
  };

  for (final MapEntry(key: type, value: button) in buttons.entries) {
    // goldenTest returns Future<void>; the test framework tracks the
    // registration itself, so we intentionally don't await it here.
    unawaited(
      goldenTest(
        'the $type button draws its ring on keyboard focus',
        fileName: 'button_focus_ring_$type',
        constraints: const BoxConstraints.tightFor(width: 390),
        builder: () => GoldenTestGroup(
          columns: 2,
          children: [
            GoldenTestScenario(
              name: 'keyboard focus',
              child: _OnSurface(child: button(autofocus: true)),
            ),
            GoldenTestScenario(
              name: 'at rest',
              child: _OnSurface(child: button(autofocus: false)),
            ),
          ],
        ),
        // Alchemist's harness has no `WidgetsApp`, so no Tab shortcut: the
        // first button takes focus itself, and a key press makes that focus
        // the keyboard's.
        whilePerforming: (tester) async {
          await tester.sendKeyEvent(LogicalKeyboardKey.shift);
          await tester.pumpAndSettle();
          return null;
        },
      ),
    );
  }
}

/// [child] on the light theme's surface, with room around it for a ring.
class _OnSurface extends StatelessWidget {
  const _OnSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = BgeTheme.light();
    final tokens = theme.extension<BgeTokens>()!;
    return Theme(
      data: theme,
      child: Material(
        color: theme.colorScheme.surface,
        child: Padding(padding: EdgeInsets.all(tokens.spaceMd), child: child),
      ),
    );
  }
}
