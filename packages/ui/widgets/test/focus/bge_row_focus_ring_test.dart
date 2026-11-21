import 'dart:ui' show Tristate;

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/src/focus/pointer_focus_flag.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _afterKey = Key('after');

/// A tappable list row, ringed when it has the keyboard's focus (#758): its
/// ink's tint alone stands about 1.3:1 from its rest.
void main() {
  final boundary = GlobalKey();

  final themes = {
    'light': BgeTheme.light,
    'dark': BgeTheme.dark,
    'highContrastLight': BgeTheme.highContrastLight,
    'highContrastDark': BgeTheme.highContrastDark,
  };

  /// [row] at the top left of a 390 by 844 window, in [theme], else the
  /// light theme, with a button after it to which focus can go.
  Future<void> host(
    WidgetTester tester,
    Widget row, {
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    row,
                    TextButton(
                      key: _afterKey,
                      onPressed: () {},
                      child: const Text('After'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A ringed list tile titled "Row", as a call site builds it.
  Widget ringedTile({
    VoidCallback? onTap,
    FocusNode? focusNode,
    bool focusOnTap = false,
    void Function(BgeRowFocus row)? seen,
  }) => BgeRowFocusRing(
    focusNode: focusNode,
    focusOnTap: focusOnTap,
    builder: (context, row) {
      seen?.call(row);
      return ListTile(
        focusNode: row.focusNode,
        onFocusChange: row.onFocusChange,
        focusColor: row.focusColor,
        onTap: row.onTap(onTap),
        title: const Text('Row'),
      );
    },
  );

  Future<void> tab(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }

  /// Whether the focus anywhere in the row stands 3:1 from [atRest] now.
  Future<bool> focusShows(WidgetTester tester, Pixels atRest) async {
    final rect = tester.getRect(find.byType(BgeRowFocusRing));
    final now = await capturePixels(tester, boundary);
    return strongestContrast(rect, atRest, now) >= 3.0;
  }

  // Anywhere the focus shows: a fill, a ring, an edge. Moved from ui_tokens'
  // pinned check, which measured a raw `ListTile` at 1.32 / 1.47 / 1.32 /
  // 1.48 (#758).
  group("a list row's keyboard focus differs from its rest by 3:1 (#758)", () {
    final placements = <String, Widget Function(Widget row)>{
      'plain': (row) => row,
      'inside BgeOutlinedRow': (row) => BgeOutlinedRow(child: row),
    };

    Future<void> measure(
      WidgetTester tester,
      Widget row, {
      ThemeData? theme,
    }) async {
      await host(tester, row, theme: theme);
      final rect = tester.getRect(find.byType(BgeRowFocusRing));
      final atRest = await capturePixels(tester, boundary);

      await tab(tester);
      await tester.pumpAndSettle();
      expect(
        Focus.of(tester.element(find.text('Row'))).hasPrimaryFocus,
        isTrue,
      );
      final focused = await capturePixels(tester, boundary);

      expect(
        strongestContrast(rect, atRest, focused),
        greaterThanOrEqualTo(3.0),
      );
    }

    for (final MapEntry(key: name, value: build) in themes.entries) {
      for (final MapEntry(key: placement, value: place) in placements.entries) {
        testWidgets('$name, $placement', (tester) async {
          await measure(
            tester,
            place(ringedTile(onTap: () {})),
            theme: build(),
          );
        });
      }
    }

    final selectionTiles = <String, Widget Function(BgeRowFocus row)>{
      'CheckboxListTile': (row) => CheckboxListTile(
        focusNode: row.focusNode,
        onFocusChange: row.onFocusChange,
        value: false,
        onChanged: (_) {},
        title: const Text('Row'),
      ),
      'SwitchListTile': (row) => SwitchListTile(
        focusNode: row.focusNode,
        onFocusChange: row.onFocusChange,
        value: false,
        onChanged: (_) {},
        title: const Text('Row'),
      ),
      'RadioListTile': (row) => RadioGroup<int>(
        groupValue: 0,
        onChanged: (_) {},
        child: RadioListTile<int>(
          focusNode: row.focusNode,
          onFocusChange: row.onFocusChange,
          value: 1,
          title: const Text('Row'),
        ),
      ),
    };

    for (final MapEntry(key: name, value: build) in selectionTiles.entries) {
      testWidgets('$name, light', (tester) async {
        await measure(
          tester,
          BgeRowFocusRing(builder: (context, row) => build(row)),
        );
      });
    }
  });

  testWidgets(
    'no ring after a mouse click, and the next key press brings it back',
    (tester) async {
      await host(tester, ringedTile(onTap: () {}, focusOnTap: true));
      final atRest = await capturePixels(tester, boundary);
      final row = tester.getCenter(find.byType(BgeRowFocusRing));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(row);
      await mouse.down(row);
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.up();
      // Away, so no hover tint is left on the row.
      await mouse.moveTo(const Offset(300, 700));
      await tester.pumpAndSettle();

      expect(
        Focus.of(tester.element(find.text('Row'))).hasPrimaryFocus,
        isTrue,
        reason: 'the click gave the row focus',
      );
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      expect(await focusShows(tester, atRest), isFalse, reason: 'clicked');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(await focusShows(tester, atRest), isTrue, reason: 'a key press');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('focusOnTap puts focus on the row before the tap runs', (
    tester,
  ) async {
    late BgeRowFocus focus;
    bool? focusedWhenTapped;
    await host(
      tester,
      ringedTile(
        focusOnTap: true,
        seen: (row) => focus = row,
        onTap: () => focusedWhenTapped = focus.focusNode.hasPrimaryFocus,
      ),
    );

    await tester.tap(find.text('Row'));
    await tester.pump();

    expect(focusedWhenTapped, isTrue);
  });

  testWidgets('without focusOnTap a tap moves no focus', (tester) async {
    late BgeRowFocus focus;
    var taps = 0;
    await host(
      tester,
      ringedTile(seen: (row) => focus = row, onTap: () => taps++),
    );

    await tester.tap(find.text('Row'));
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(focus.focusNode.hasFocus, isFalse);
  });

  testWidgets('a null tap stays null, with focusOnTap or without', (
    tester,
  ) async {
    void tap() {}
    for (final focusOnTap in [false, true]) {
      late BgeRowFocus focus;
      await host(
        tester,
        ringedTile(focusOnTap: focusOnTap, seen: (row) => focus = row),
      );
      expect(focus.onTap(null), isNull, reason: 'focusOnTap: $focusOnTap');
      if (!focusOnTap) {
        expect(focus.onTap(tap), same(tap), reason: 'the tap itself');
      }
    }
  });

  testWidgets("a given focusNode is the tile's", (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    late BgeRowFocus focus;
    await host(
      tester,
      ringedTile(focusNode: node, seen: (row) => focus = row, onTap: () {}),
    );

    expect(focus.focusNode, same(node));
    await tab(tester);
    expect(node.hasPrimaryFocus, isTrue);
  });

  testWidgets('the tile follows the given node as it changes, and the ring '
      "never disposes the caller's", (tester) async {
    final first = FocusNode(debugLabel: 'first');
    final second = FocusNode(debugLabel: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    late BgeRowFocus focus;
    Future<void> showWith(FocusNode? node) => host(
      tester,
      ringedTile(focusNode: node, seen: (row) => focus = row, onTap: () {}),
    );

    await showWith(first);
    expect(focus.focusNode, same(first));

    await showWith(second);
    expect(focus.focusNode, same(second));
    await tab(tester);
    expect(second.hasPrimaryFocus, isTrue, reason: 'the tile has the new node');
    expect(first.hasFocus, isFalse);

    await showWith(null);
    final own = focus.focusNode;
    expect(own, isNot(anyOf(same(first), same(second))));

    await showWith(first);
    expect(focus.focusNode, same(first));
    first.requestFocus();
    await tester.pump();
    expect(first.hasPrimaryFocus, isTrue, reason: 'given back, it still works');

    // Unmounted: the caller's nodes are still the caller's to use. A
    // disposed node asserts on a listener added or removed.
    await tester.pumpWidget(const SizedBox());
    void listener() {}
    for (final node in [first, second]) {
      expect(
        () => node
          ..addListener(listener)
          ..removeListener(listener),
        returnsNormally,
        reason: '${node.debugLabel} is not disposed',
      );
    }
  });

  testWidgets('an inert row is no focus stop and draws no ring', (
    tester,
  ) async {
    late BgeRowFocus focus;
    await host(tester, ringedTile(seen: (row) => focus = row));
    final atRest = await capturePixels(tester, boundary);

    await tab(tester);
    await tester.pumpAndSettle();

    expect(focus.focusNode.hasFocus, isFalse);
    expect(
      Focus.of(tester.element(find.text('After'))).hasPrimaryFocus,
      isTrue,
      reason: 'Tab passes the row',
    );
    expect(await focusShows(tester, atRest), isFalse);
  });

  testWidgets('the row stays one semantics node with its tap action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    // Disposed in `finally`, not a tear-down: the test checks for a live
    // handle before any tear-down runs.
    try {
      await host(tester, MergeSemantics(child: ringedTile(onTap: () {})));

      final merged = tester.getSemantics(find.byType(MergeSemantics));
      final data = merged.getSemanticsData();
      expect(data.label, 'Row');
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(
        data.flagsCollection.isFocused,
        isNot(Tristate.none),
        reason: 'focusable',
      );

      // No other node a screen reader stops on carries the row's words or a
      // tap: the ring and the pointer's listener add none.
      final stops = <SemanticsNode>[];
      bool visit(SemanticsNode node) {
        final data = node.getSemanticsData();
        final ours =
            data.label.contains('Row') ||
            (data.hasAction(SemanticsAction.tap) && data.label != 'After');
        if (!node.isMergedIntoParent && ours) {
          stops.add(node);
        }
        node.visitChildren(visit);
        return true;
      }

      visit(
        tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!,
      );
      expect(
        stops.map((node) => node.id),
        [merged.id],
      );
    } finally {
      handle.dispose();
    }
  });

  /// Whether the ring around the row with [words] is drawn now.
  bool ringDrawn(WidgetTester tester, Finder words) {
    final ring = find.ancestor(of: words, matching: find.byType(BgeFocusRing));
    // The ring's own outer box comes first in its subtree.
    final box = tester.widget<DecoratedBox>(
      find.descendant(of: ring, matching: find.byType(DecoratedBox)).first,
    );
    return (box.decoration as BoxDecoration).border != null;
  }

  testWidgets('a focused node given up for one with no focus takes the ring '
      'with it; the same node given again keeps it', (tester) async {
    final first = FocusNode(debugLabel: 'first');
    final second = FocusNode(debugLabel: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Future<void> showWith(FocusNode node) =>
        host(tester, ringedTile(focusNode: node, onTap: () {}));

    await showWith(first);
    await tab(tester);
    expect(first.hasPrimaryFocus, isTrue);
    expect(ringDrawn(tester, find.text('Row')), isTrue, reason: 'focused');

    await showWith(first);
    expect(
      ringDrawn(tester, find.text('Row')),
      isTrue,
      reason: 'the same node, still focused',
    );

    await showWith(second);
    expect(second.hasPrimaryFocus, isFalse);
    expect(
      ringDrawn(tester, find.text('Row')),
      isFalse,
      reason: 'the new node has no focus',
    );
  });

  testWidgets(
    "a held key's repeat after a click brings the ring back, as its press "
    'would',
    (tester) async {
      await host(tester, ringedTile(onTap: () {}, focusOnTap: true));
      final row = tester.getCenter(find.byType(BgeRowFocusRing));

      // Held from before the click, so what follows it is a repeat.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.down(row);
      await mouse.up();
      await tester.pump();
      expect(
        Focus.of(tester.element(find.text('Row'))).hasPrimaryFocus,
        isTrue,
        reason: 'the click gave the row focus',
      );
      expect(ringDrawn(tester, find.text('Row')), isFalse, reason: 'clicked');

      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(ringDrawn(tester, find.text('Row')), isTrue, reason: 'a repeat');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    "the ring is the tile's own: none while focus is on a control in its "
    'trailing',
    (tester) async {
      await host(
        tester,
        BgeRowFocusRing(
          builder: (context, row) => ListTile(
            focusNode: row.focusNode,
            onFocusChange: row.onFocusChange,
            focusColor: row.focusColor,
            onTap: row.onTap(() {}),
            title: const Text('Row'),
            trailing: IconButton(
              onPressed: () {},
              icon: const Icon(Icons.more_vert),
            ),
          ),
        ),
      );

      await tab(tester);
      expect(
        Focus.of(tester.element(find.text('Row'))).hasPrimaryFocus,
        isTrue,
      );
      expect(ringDrawn(tester, find.text('Row')), isTrue, reason: 'the tile');

      await tab(tester);
      expect(
        Focus.of(tester.element(find.byIcon(Icons.more_vert))).hasPrimaryFocus,
        isTrue,
        reason: 'Tab goes on to the menu inside the tile',
      );
      expect(
        ringDrawn(tester, find.text('Row')),
        isFalse,
        reason: 'the menu has focus, not the row',
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tab(tester);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(ringDrawn(tester, find.text('Row')), isTrue, reason: 'back');

      await tab(tester);
      await tab(tester);
      expect(
        ringDrawn(tester, find.text('Row')),
        isFalse,
        reason: 'focus has left the row',
      );
    },
  );

  testWidgets(
    'outsideSides draws the ring outside the box at its sides, clear of a '
    'tile with no content padding',
    (tester) async {
      await host(
        tester,
        BgeRowFocusRing(
          outsideSides: true,
          builder: (context, row) => SwitchListTile(
            focusNode: row.focusNode,
            onFocusChange: row.onFocusChange,
            contentPadding: EdgeInsets.zero,
            value: false,
            onChanged: (_) {},
            title: const Text('Row'),
          ),
        ),
      );
      final box = tester.getRect(find.byType(SwitchListTile));
      final title = tester.getRect(find.text('Row'));
      expect(title.left, box.left, reason: 'the title runs to the side');
      final atRest = await capturePixels(tester, boundary);

      await tab(tester);
      await tester.pumpAndSettle();
      expect(ringDrawn(tester, find.text('Row')), isTrue);
      final focused = await capturePixels(tester, boundary);

      final primary = BgeTheme.light().colorScheme.primary;
      final width = BgeTheme.light().extension<BgeTokens>()!.focusOutlineWidth;
      final y = title.center.dy;
      expect(
        focused(Offset(box.left - width / 2, y)),
        primary,
        reason: 'the ring sits outside the left side',
      );
      expect(
        focused(Offset(box.right + width / 2, y)),
        primary,
        reason: 'and outside the right',
      );
      for (var x = title.left; x < title.left + width; x++) {
        expect(
          focused(Offset(x + 0.5, y)),
          atRest(Offset(x + 0.5, y)),
          reason: "the title's first column at $x is as it was",
        );
      }
    },
  );

  testWidgets(
    "an inert row's mouse press leaves the shared pointer flag alone",
    (tester) async {
      final flag = PointerFocusFlag();
      addTearDown(flag.dispose);
      const inertKey = Key('inert');
      await host(
        tester,
        PointerFocusFlagScope(
          flag: flag,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: inertKey,
                width: 300,
                child: ringedTile(),
              ),
              SizedBox(width: 300, child: ringedTile(onTap: () {})),
            ],
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);

      final inert = tester.getCenter(find.byKey(inertKey));
      await mouse.down(inert);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(flag.value, isFalse, reason: 'the inert row takes no focus');

      final tappable = tester.getCenter(find.byType(ListTile).last);
      await mouse.down(tappable);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(flag.value, isTrue, reason: 'a row that takes a tap notes it');
    },
  );
}
