// One cell's body, which the barrel hides: a declared cell that fails is a
// red test, so the guard's failures are watched through it instead.
import 'package:bge_test_support/src/widgets/accessibility_audit.dart'
    show runAuditCell;
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The running test's full name, groups included, to pin the names
// auditScreen declares. `WidgetTester.testDescription` holds only the
// testWidgets' own.
import 'package:test_api/hooks.dart' show TestHandle;
import 'package:ui_tokens/ui_tokens.dart';

/// The failure [body] throws, or null. Not `expectLater(body(), throwsA(..))`:
/// that makes the tester's guarded `expectLater` overlap the helper's own.
Future<TestFailure?> _failureOf(Future<void> Function() body) async {
  try {
    await body();
  } on TestFailure catch (e) {
    return e;
  }
  return null;
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// A screen with one line of text, in [theme].
Widget _screen(ThemeData theme, {TransitionBuilder? builder}) => MaterialApp(
  theme: theme,
  builder: builder,
  home: const Scaffold(body: Center(child: Text('hello'))),
);

void main() {
  group('expectMeetsAccessibilityGuidelines', () {
    testWidgets('an unlabeled IconButton fails the audit', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(IconButton(icon: const Icon(Icons.add), onPressed: () {})),
      );

      final failure = await _failureOf(
        () => expectMeetsAccessibilityGuidelines(tester),
      );
      expect(failure?.message, contains(labeledTapTargetGuideline.description));
      handle.dispose();
    });

    testWidgets('a 30dp tap target fails', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          Semantics(
            label: 'tiny',
            button: true,
            child: GestureDetector(
              onTap: () {},
              child: const SizedBox(width: 30, height: 30),
            ),
          ),
        ),
      );

      final failure = await _failureOf(
        () => expectMeetsAccessibilityGuidelines(tester),
      );
      expect(failure, isNotNull);
      handle.dispose();
    });

    testWidgets('a labelled, large target passes', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          IconButton(
            tooltip: 'Add',
            icon: const Icon(Icons.add),
            onPressed: () {},
          ),
        ),
      );

      await expectMeetsAccessibilityGuidelines(tester);
      handle.dispose();
    });

    // The negative control for contrast, as the IconButton is for labels: a
    // check that stopped running would leave every screen audit green.
    testWidgets('pale text fails the contrast check', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const Text('faint', style: TextStyle(color: Color(0xFFCCCCCC)))),
      );

      final failure = await _failureOf(
        () => expectMeetsAccessibilityGuidelines(tester),
      );
      expect(failure?.message, contains(textContrastGuideline.description));
      expect(
        await _failureOf(
          () => expectMeetsAccessibilityGuidelines(tester, textContrast: false),
        ),
        isNull,
        reason: 'textContrast: false skips it',
      );
      handle.dispose();
    });
  });

  group('audit matrix', () {
    test('covers the two viewports and both themes', () {
      expect(kAuditViewports.map((v) => v.label), [
        '320dp × 2.0',
        '390dp × 1.0',
      ]);
      expect(kAuditThemes.keys, ['light', 'dark']);
    });
  });

  group('auditScreen settle: false', () {
    auditScreen(
      'spinner',
      settle: false,
      build: (theme) => MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: Semantics(
              label: 'Loading',
              child: const CircularProgressIndicator(),
            ),
          ),
        ),
      ),
    );
  });

  group('auditScreen', () {
    group('build gets only the theme', () {
      /// What each cell was given, by its test's name: the view's logical
      /// size and the theme.
      final cells = <String, (Size, ThemeData)>{};

      auditScreen(
        'probe',
        build: (theme) {
          final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
          cells[TestHandle.current.name] = (
            view.physicalSize / view.devicePixelRatio,
            theme,
          );
          return _screen(theme);
        },
      );

      // Runs once the group's tests have finished, in whatever order they
      // ran. The expected cells are written out rather than read from the
      // matrix, so a change to what a cell is given can't pass unnoticed.
      tearDownAll(() {
        final light = BgeTheme.light();
        final dark = BgeTheme.dark();
        expect(
          cells.keys.toSet(),
          {
            'auditScreen build gets only the theme probe — 320dp × 2.0, light',
            'auditScreen build gets only the theme probe — 320dp × 2.0, dark',
            'auditScreen build gets only the theme probe — 390dp × 1.0, light',
            'auditScreen build gets only the theme probe — 390dp × 1.0, dark',
          },
          reason: 'one test per viewport x theme, each named by both',
        );
        for (final MapEntry(key: name, value: (size, theme)) in cells.entries) {
          expect(
            size,
            name.contains('320dp')
                ? const Size(320, 800)
                : const Size(390, 844),
            reason: '$name: view size',
          );
          expect(
            theme,
            same(name.endsWith('light') ? light : dark),
            reason: '$name: theme',
          );
        }
      });
    });

    group('pump gets the tester and the theme', () {
      /// The theme each cell's pump was given, by its test's name.
      final themes = <String, ThemeData>{};

      auditScreen(
        'pumped',
        pump: (tester, theme) {
          themes[TestHandle.current.name] = theme;
          return tester.pumpWidget(_screen(theme));
        },
      );

      tearDownAll(() {
        const name = 'auditScreen pump gets the tester and the theme pumped';
        expect(themes, {
          '$name — 320dp × 2.0, light': same(BgeTheme.light()),
          '$name — 320dp × 2.0, dark': same(BgeTheme.dark()),
          '$name — 390dp × 1.0, light': same(BgeTheme.light()),
          '$name — 390dp × 1.0, dark': same(BgeTheme.dark()),
        });
      });
    });

    group('each cell draws at its scale', () {
      /// What the screen's own scaler makes of 10, by its test's name.
      final scaled = <String, double>{};

      auditScreen(
        'probe',
        build: (theme) => MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) {
                  scaled[TestHandle.current.name] = MediaQuery.textScalerOf(
                    context,
                  ).scale(10);
                  return const Text('hello');
                },
              ),
            ),
          ),
        ),
      );

      tearDownAll(() {
        expect(scaled, {
          'auditScreen each cell draws at its scale probe — 320dp × 2.0, light':
              20,
          'auditScreen each cell draws at its scale probe — 320dp × 2.0, dark':
              20,
          'auditScreen each cell draws at its scale probe — 390dp × 1.0, light':
              10,
          'auditScreen each cell draws at its scale probe — 390dp × 1.0, dark':
              10,
        });
      });
    });

    group('a harness that forces its own scale fails the cell', () {
      for (final viewport in kAuditViewports) {
        for (final MapEntry(key: themeName, value: theme)
            in kAuditThemes.entries) {
          testWidgets('— ${viewport.label}, $themeName', (tester) async {
            final failure = await _failureOf(
              () => runAuditCell(
                tester,
                viewport,
                theme(),
                pump: (tester, theme) => tester.pumpWidget(
                  _screen(
                    theme,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.noScaling),
                      child: child!,
                    ),
                  ),
                ),
              ),
            );

            if (viewport.textScale == 1) {
              expect(
                failure,
                isNull,
                reason: "the scale it forces is the cell's",
              );
            } else {
              // The scale's own message: not the theme's, nor the one for a
              // screen drawn at each but never both at once.
              expect(
                failure?.message,
                allOf(
                  contains(
                    "the harness overrides the cell's text scale: the screen "
                    'is drawn at 1.0, not ${viewport.textScale}',
                  ),
                  isNot(contains("cell's theme")),
                ),
              );
            }
          });
        }
      }
    });

    group('a harness that ignores the theme fails the cell', () {
      for (final viewport in kAuditViewports) {
        for (final MapEntry(key: themeName, value: theme)
            in kAuditThemes.entries) {
          testWidgets('— ${viewport.label}, $themeName', (tester) async {
            final failure = await _failureOf(
              () => runAuditCell(
                tester,
                viewport,
                theme(),
                pump: (tester, _) =>
                    tester.pumpWidget(_screen(BgeTheme.light())),
              ),
            );

            if (themeName == 'light') {
              expect(
                failure,
                isNull,
                reason: "the theme it forces is the cell's",
              );
            } else {
              expect(
                failure?.message,
                contains("the harness overrides the cell's theme"),
              );
            }
          });
        }
      }
    });

    // The old guard passed both: one piece of text at the cell was enough.
    testWidgets("a harness that overrides one route's scale fails the cell", (
      tester,
    ) async {
      final failure = await _failureOf(
        () => runAuditCell(
          tester,
          kAuditViewports.first,
          BgeTheme.light(),
          pump: (tester, theme) => tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Column(
                children: [
                  const Expanded(child: Scaffold(body: Text('at the cell'))),
                  Expanded(
                    child: MediaQuery.withNoTextScaling(
                      child: const Scaffold(body: Text('at 1.0')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(
        failure?.message,
        contains(
          "the harness overrides the cell's text scale: the screen is drawn "
          'at 1.0, not 2.0',
        ),
      );
    });

    testWidgets("a harness that swaps in Flutter's dark theme fails the cell", (
      tester,
    ) async {
      final failure = await _failureOf(
        () => runAuditCell(
          tester,
          kAuditViewports.last,
          BgeTheme.dark(),
          pump: (tester, _) => tester.pumpWidget(_screen(ThemeData.dark())),
        ),
      );

      expect(
        failure?.message,
        contains(
          "the harness overrides the cell's theme: the screen is not drawn in "
          "the cell's dark colour scheme",
        ),
      );
    });

    // Flutter clamps an app bar's title below 2.0 itself: not the harness.
    testWidgets("an app bar's clamped title passes", (tester) async {
      await runAuditCell(
        tester,
        kAuditViewports.first,
        BgeTheme.light(),
        pump: (tester, theme) => tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              appBar: AppBar(title: const Text('title')),
              body: const Text('hello'),
            ),
          ),
        ),
      );

      final title = tester.element(find.text('title'));
      expect(MediaQuery.textScalerOf(title).scale(10), lessThan(20));
    });

    testWidgets('a cell with nothing drawn fails', (tester) async {
      final failure = await _failureOf(
        () => runAuditCell(
          tester,
          kAuditViewports.first,
          BgeTheme.light(),
          pump: (tester, theme) => tester.pumpWidget(
            MaterialApp(theme: theme, home: const SizedBox.shrink()),
          ),
        ),
      );

      expect(
        failure?.message,
        contains("nothing drawn to check the cell's scale and theme on"),
      );
    });

    // The check runs in the group's tearDown, which runs after the cell's own
    // teardown, so it holds under any test order.
    group('a cell leaves the scale as it found it', () {
      tearDown(() {
        expect(
          TestWidgetsFlutterBinding.instance.platformDispatcher.textScaleFactor,
          1,
        );
      });

      testWidgets('a 320dp × 2.0 cell', (tester) async {
        await runAuditCell(
          tester,
          kAuditViewports.first,
          BgeTheme.light(),
          pump: (tester, theme) => tester.pumpWidget(_screen(theme)),
        );
        expect(tester.platformDispatcher.textScaleFactor, 2);
      });
    });

    group('build and pump together, or neither, throw', () {
      // In a test body, so the throw is the helper's own and not group()'s,
      // which refuses to declare a group while a test runs.
      test('neither', () {
        expect(() => auditScreen('x'), throwsArgumentError);
      });

      test('both', () {
        expect(
          () => auditScreen(
            'x',
            build: _screen,
            pump: (tester, theme) => tester.pumpWidget(_screen(theme)),
          ),
          throwsArgumentError,
        );
      });
    });
  });
}
