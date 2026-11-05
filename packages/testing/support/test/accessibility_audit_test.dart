import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The running test's full name, groups included, to pin the names
// auditScreen declares. `WidgetTester.testDescription` holds only the
// testWidgets' own.
import 'package:test_api/hooks.dart' show TestHandle;

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
      build: (theme, textScaler) => MaterialApp(
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
    final names = <String>[];

    auditScreen(
      'probe',
      build: (theme, textScaler) {
        names.add(TestHandle.current.name);
        return MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
          home: const Scaffold(body: Center(child: Text('hello'))),
        );
      },
    );

    // Runs once the group's tests have finished, in whatever order they ran.
    tearDownAll(() {
      expect(
        names.toSet(),
        {
          'auditScreen probe — 320dp × 2.0, light',
          'auditScreen probe — 320dp × 2.0, dark',
          'auditScreen probe — 390dp × 1.0, light',
          'auditScreen probe — 390dp × 1.0, dark',
        },
        reason: 'one test per viewport x theme, each named by both',
      );
      expect(names, hasLength(4));
    });
  });
}
