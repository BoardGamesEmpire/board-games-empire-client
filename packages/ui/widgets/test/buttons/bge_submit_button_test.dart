import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(
  Widget child, {
  Size size = const Size(320, 640),
  double scale = 1,
}) {
  return MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: BgeTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('BgeSubmitButton in-flight layout (#163)', () {
    // The issue measured the equivalent hand-rolled row overflowing by 56px at
    // 320dp and 298px at textScaler 2.0. Those are the two cases that must
    // stay clean, forever, at every call site — which is the reason this
    // treatment lives in a widget rather than in a documented pattern.
    for (final (name, size, scale) in <(String, Size, double)>[
      ('narrow phone', Size(320, 640), 1),
      ('narrow phone at 2.0 text scale', Size(320, 640), 2),
      ('very narrow', Size(240, 640), 2),
    ]) {
      testWidgets('does not overflow: $name', (tester) async {
        await tester.pumpWidget(
          _host(
            const BgeSubmitButton(
              label: 'Add server',
              progressLabel: 'Contacting server…',
              submitting: true,
              onPressed: null,
            ),
            size: size,
            scale: scale,
          ),
        );

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('keeps the full label in semantics despite visual ellipsis', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const BgeSubmitButton(
            label: 'Add server',
            progressLabel: 'Contacting server…',
            submitting: true,
            onPressed: null,
          ),
          size: const Size(240, 640),
          scale: 2,
        ),
      );

      // Ellipsis is a painting concern; the semantics label is not truncated,
      // so a screen reader still hears the whole string.
      expect(find.text('Contacting server…'), findsOneWidget);
    });
  });

  group('BgeSubmitButton accessibility contract', () {
    testWidgets('is disabled but still present while submitting', (
      tester,
    ) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(
          BgeSubmitButton(
            label: 'Submit',
            progressLabel: 'Submitting…',
            submitting: true,
            onPressed: () => pressed++,
          ),
        ),
      );

      expect(find.byType(FilledButton), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      expect(pressed, 0, reason: 'a submitting button must not re-fire');
    });

    testWidgets('retains an accessible name while submitting', (tester) async {
      await tester.pumpWidget(
        _host(
          const BgeSubmitButton(
            label: 'Create household',
            progressLabel: 'Creating household…',
            submitting: true,
            onPressed: null,
          ),
        ),
      );

      // A bare spinner would announce as an unnamed button.
      expect(find.text('Creating household…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('announces the state change via a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeSubmitButton(
            label: 'Submit',
            progressLabel: 'Submitting…',
            submitting: true,
            onPressed: null,
          ),
        ),
      );

      // `isSemantics`, not `matchesSemantics`: the button's own flags merge
      // onto this node, which is the desired outcome — a screen reader gets
      // ONE stop ("Submitting…", button, disabled) rather than a nameless
      // button followed by a stray live region. An exhaustive matcher would
      // force this test to re-list Material's button flags forever.
      expect(
        tester.getSemantics(find.text('Submitting…')),
        isSemantics(
          label: 'Submitting…',
          isLiveRegion: true,
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('falls back to the resting label when no progress label is '
        'given', (tester) async {
      await tester.pumpWidget(
        _host(
          const BgeSubmitButton(
            label: 'Submit',
            submitting: true,
            onPressed: null,
          ),
        ),
      );

      // Never a nameless button, even when the caller forgot the string.
      expect(find.text('Submit'), findsOneWidget);
    });

    testWidgets('a null onPressed disables it independently of submitting', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const BgeSubmitButton(label: 'Submit', onPressed: null)),
      );

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });
  });

  group('BgeSubmitButton resting state', () {
    testWidgets('fires onPressed', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(BgeSubmitButton(label: 'Submit', onPressed: () => pressed++)),
      );

      await tester.tap(find.byType(FilledButton));
      expect(pressed, 1);
    });

    testWidgets('does not overflow with an icon at 2.0 text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const BgeSubmitButton(
            label: 'Add to collection',
            icon: Icons.add,
            onPressed: null,
          ),
          size: const Size(240, 640),
          scale: 2,
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
