import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The failure [body] throws, or null. Not `expectLater(body(), throwsA(..))`:
/// that makes the tester's guarded `expectLater` overlap the helper's own
/// guarded calls.
Future<TestFailure?> _failureOf(Future<void> Function() body) async {
  try {
    await body();
  } on TestFailure catch (e) {
    return e;
  }
  return null;
}

Widget _three({Widget Function(Widget)? wrapSecond}) {
  Widget b = TextButton(onPressed: () {}, child: const Text('B'));
  if (wrapSecond != null) b = wrapSecond(b);
  return Column(
    children: [
      TextButton(onPressed: () {}, child: const Text('A')),
      b,
      TextButton(onPressed: () {}, child: const Text('C')),
    ],
  );
}

/// One page under a router, as `BgeApp`'s go_router hosts its routes: a
/// `MaterialApp.router` builds no "Navigator Scope" above the navigator, as
/// `MaterialApp(home:)` does, so a route's scope sits right under the View's.
class _OnePageRouter extends RouterDelegate<Object>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<Object> {
  _OnePageRouter(
    this.page, {
    this.edge = kDefaultRouteTraversalEdgeBehavior,
  });

  final Widget page;

  /// What Tab does past the route's last control.
  final TraversalEdgeBehavior edge;

  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => Navigator(
    key: navigatorKey,
    routeTraversalEdgeBehavior: edge,
    pages: [MaterialPage<void>(child: page)],
    onDidRemovePage: (_) {},
  );

  @override
  Future<void> setNewRoutePath(Object configuration) async {}
}

void main() {
  group('tabOrder', () {
    testWidgets('reports Tab order by label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_three()));

      expect(await tabOrder(tester), ['A', 'B', 'C']);
      handle.dispose();
    });

    testWidgets('reverse walks the other way', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_three()));

      expect(await tabOrder(tester, reverse: true), ['C', 'B', 'A']);
      handle.dispose();
    });

    // What a screen reader reads: a control whose words are merged into its
    // node from below has an empty label of its own (#50).
    testWidgets('names a control by the label merged into its node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              MergeSemantics(
                child: ListTile(onTap: () {}, title: const Text('Row')),
              ),
              FloatingActionButton.extended(
                onPressed: () {},
                label: const Text('Create'),
              ),
            ],
          ),
        ),
      );

      expect(await tabOrder(tester), ['Row', 'Create']);
      handle.dispose();
    });

    testWidgets('names an icon button by its tooltip', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          IconButton(
            tooltip: 'Clear',
            onPressed: () {},
            icon: const Icon(Icons.clear),
          ),
        ),
      );

      expect(await tabOrder(tester), ['Clear']);
      handle.dispose();
    });

    testWidgets('reads <unnamed> for a control with no name', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(IconButton(onPressed: () {}, icon: const Icon(Icons.clear))),
      );

      expect(await tabOrder(tester), ['<unnamed>']);
      handle.dispose();
    });

    // A debug label is for the developer; no screen reader reads it, so it
    // can't stand in for a name (#50).
    testWidgets('reads <unnamed> for a control named only by its debug label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final node = FocusNode(debugLabel: 'Clear');
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          IconButton(
            focusNode: node,
            onPressed: () {},
            icon: const Icon(Icons.clear),
          ),
        ),
      );

      expect(await tabOrder(tester), ['<unnamed>']);
      handle.dispose();
    });
  });

  group('tabStops', () {
    testWidgets("gives tabOrder's names with each stop's focus node", (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(_three()));

      final stops = await tabStops(tester);

      expect([for (final stop in stops) stop.name], ['A', 'B', 'C']);
      for (final (index, label) in ['A', 'B', 'C'].indexed) {
        expect(
          stops[index].node,
          same(Focus.of(tester.element(find.text(label)))),
        );
      }
      semantics.dispose();
    });
  });

  group('expectTraversable', () {
    testWidgets('passes for a plain column and checks expectedOrder', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_three()));

      await expectTraversable(tester, expectedOrder: ['A', 'B', 'C']);
      expect(
        await _failureOf(
          () => expectTraversable(tester, expectedOrder: ['A', 'C', 'B']),
        ),
        isNotNull,
      );
      handle.dispose();
    });

    // Unfocusing a route's own scope would hand focus to the scope above it.
    // Under a router that is the View's, above the app's keyboard shortcuts,
    // where Tab does nothing (#50).
    testWidgets('walks a route under a router from the route itself', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: RouterConfig(
            routerDelegate: _OnePageRouter(Scaffold(body: _three())),
          ),
        ),
      );
      expect(
        FocusManager.instance.primaryFocus,
        isA<FocusScopeNode>(),
        reason: 'the route opens with focus on its own scope',
      );

      await expectTraversable(tester, expectedOrder: ['A', 'B', 'C']);
      handle.dispose();
    });

    // A navigation bar outside the page's route (#414): Tab goes round the
    // page from its first stop and on through the bar, and Shift+Tab goes
    // the other way from the page's last stop.
    testWidgets('walks a circle that runs on past the page', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              Expanded(
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => Material(child: _three()),
                  ),
                ),
              ),
              TextButton(onPressed: () {}, child: const Text('X')),
              TextButton(onPressed: () {}, child: const Text('Y')),
            ],
          ),
        ),
      );
      expect(await tabOrder(tester), ['A', 'B', 'C', 'X', 'Y']);
      // From the page again: the reverse walk starts at its last stop.
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      expect(await tabOrder(tester, reverse: true), ['C', 'B', 'A', 'Y', 'X']);

      await expectTraversable(tester, expectedOrder: ['A', 'B', 'C', 'X', 'Y']);
      handle.dispose();
    });

    // Shift+Tab from the page enters at the page's last stop. A reverse walk
    // that goes round the same circle from any other stop on it, here X
    // outside the page, fails (#414).
    testWidgets("fails when Shift+Tab enters anywhere but the page's last "
        'stop', (tester) async {
      final handle = tester.ensureSemantics();
      final x = FocusNode();
      addTearDown(x.dispose);
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              Expanded(
                // Takes the first Shift+Tab from the page, while the page's
                // scope has focus, and puts focus on X instead of C.
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent ||
                        event.logicalKey != LogicalKeyboardKey.tab ||
                        !HardwareKeyboard.instance.isShiftPressed ||
                        FocusManager.instance.primaryFocus is! FocusScopeNode) {
                      return KeyEventResult.ignored;
                    }
                    x.requestFocus();
                    return KeyEventResult.handled;
                  },
                  child: Navigator(
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => Material(child: _three()),
                    ),
                  ),
                ),
              ),
              TextButton(
                focusNode: x,
                onPressed: () {},
                child: const Text('X'),
              ),
              TextButton(onPressed: () {}, child: const Text('Y')),
            ],
          ),
        ),
      );
      expect(await tabOrder(tester), ['A', 'B', 'C', 'X', 'Y']);
      // From the page again: the reverse walk is the right circle, entered
      // at X.
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      expect(await tabOrder(tester, reverse: true), ['X', 'C', 'B', 'A', 'Y']);

      final failure = await _failureOf(
        () => expectTraversable(
          tester,
          expectedOrder: ['A', 'B', 'C', 'X', 'Y'],
        ),
      );
      expect(failure?.message, contains("page's last stop"));
      handle.dispose();
    });

    testWidgets('starts from the page when a control has focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_three()));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));

      await expectTraversable(tester, expectedOrder: ['A', 'B', 'C']);
      handle.dispose();
    });

    testWidgets('does not call repeated labels a trap', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              for (var i = 0; i < 2; i++)
                TextButton(onPressed: () {}, child: const Text('Delete')),
            ],
          ),
        ),
      );

      await expectTraversable(tester, expectedOrder: ['Delete', 'Delete']);
      handle.dispose();
    });

    testWidgets('fails when focus has not wrapped within maxSteps', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_three()));

      final failure = await _failureOf(
        () => expectTraversable(tester, maxSteps: 2),
      );
      expect(failure?.message, contains('never wrapped within 2'));
      handle.dispose();
    });

    // Tab past the last control hands focus off the page, as a route that
    // leaves the Flutter view at its edge does, rather than wrapping (#50).
    testWidgets('fails when focus leaves the page rather than wrapping', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: RouterConfig(
            routerDelegate: _OnePageRouter(
              Scaffold(body: _three()),
              edge: TraversalEdgeBehavior.leaveFlutterView,
            ),
          ),
        ),
      );

      final failure = await _failureOf(() => expectTraversable(tester));
      expect(failure?.message, contains('Focus left the page'));
      expect(failure?.message, contains('after "C"'));
      handle.dispose();
    });

    testWidgets('detects a trap', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          _three(
            wrapSecond: (b) => FocusScope(
              onKeyEvent: (node, event) =>
                  event.logicalKey == LogicalKeyboardKey.tab
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
              child: b,
            ),
          ),
        ),
      );

      final failure = await _failureOf(() => expectTraversable(tester));
      expect(failure?.message, contains('"B" repeats'));
      handle.dispose();
    });

    // Tab walks A, B, C and wraps, and Shift+Tab walks C, B, A, the reverse,
    // then sticks on A. Its names alone match; its end doesn't (#50).
    testWidgets('detects a trap only Shift+Tab falls into', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              // Not a scope, which Tab would wrap within: a key handler on
              // A's way up the focus chain that takes no focus itself.
              Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (node, event) =>
                    event.logicalKey == LogicalKeyboardKey.tab &&
                        HardwareKeyboard.instance.isShiftPressed
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored,
                child: TextButton(onPressed: () {}, child: const Text('A')),
              ),
              TextButton(onPressed: () {}, child: const Text('B')),
              TextButton(onPressed: () {}, child: const Text('C')),
            ],
          ),
        ),
      );
      expect(await tabOrder(tester), ['A', 'B', 'C']);

      final failure = await _failureOf(() => expectTraversable(tester));
      expect(failure?.message, contains('"A" repeats under Shift+Tab'));
      handle.dispose();
    });
  });

  group('activateByKeyboard', () {
    testWidgets('Tabs to the control and presses Enter on it', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              for (final name in ['A', 'B', 'C'])
                TextButton(
                  onPressed: () => pressed.add(name),
                  child: Text(name),
                ),
            ],
          ),
        ),
      );

      await activateByKeyboard(tester, find.text('B'));

      expect(pressed, ['B']);
      expect(Focus.of(tester.element(find.text('B'))).hasPrimaryFocus, isTrue);
    });

    // A button widget's own Focus is below it, in its InkWell: the nearest
    // one above it is the route's scope, which has focus already (#50).
    testWidgets('finds a button by its widget, not only by its label', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              TextButton(
                onPressed: () => pressed.add('A'),
                child: const Text('A'),
              ),
              FilledButton(
                key: const Key('b'),
                onPressed: () => pressed.add('B'),
                child: const Text('B'),
              ),
            ],
          ),
        ),
      );

      await activateByKeyboard(tester, find.byType(FilledButton));
      expect(pressed, ['B']);

      await activateByKeyboard(tester, find.byKey(const Key('b')));
      expect(pressed, ['B', 'B'], reason: 'focused already: no Tab');
    });

    testWidgets('fails when Tab does not reach the control', (tester) async {
      await tester.pumpWidget(_host(_three()));

      final failure = await _failureOf(
        () => activateByKeyboard(tester, find.text('C'), maxSteps: 1),
      );
      expect(failure?.message, contains('Tab never reached'));
    });
  });

  group('expectFocusReturnsAfterDialog', () {
    Widget app({required FocusNode other, required bool stealFocus}) {
      return _host(
        Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () async {
                  await showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Dialog'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  );
                  if (stealFocus) other.requestFocus();
                },
                child: const Text('Open'),
              ),
              Focus(focusNode: other, child: const Text('other')),
            ],
          ),
        ),
      );
    }

    testWidgets('passes when focus comes back to the opener', (tester) async {
      final handle = tester.ensureSemantics();
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(app(other: other, stealFocus: false));

      await expectFocusReturnsAfterDialog(
        tester,
        opener: find.text('Open'),
        dismiss: () async {
          await tester.tap(find.text('Close'));
        },
      );
      handle.dispose();
    });

    testWidgets('finds the opener by its widget', (tester) async {
      final handle = tester.ensureSemantics();
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(app(other: other, stealFocus: false));

      await expectFocusReturnsAfterDialog(
        tester,
        opener: find.widgetWithText(TextButton, 'Open'),
        dismiss: () async {
          await tester.tap(find.text('Close'));
        },
      );
      handle.dispose();
    });

    testWidgets('fails when something else takes focus after pop', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(app(other: other, stealFocus: true));

      final failure = await _failureOf(
        () => expectFocusReturnsAfterDialog(
          tester,
          opener: find.text('Open'),
          dismiss: () async {
            await tester.tap(find.text('Close'));
          },
        ),
      );
      expect(failure?.message, contains('Focus must return'));
      handle.dispose();
    });
  });
}
