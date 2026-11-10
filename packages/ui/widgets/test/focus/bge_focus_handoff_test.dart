import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One item in the list: a game's, when `game` is set, drawn as a [_Row] or,
/// with `stack`, as a [_Stack]; else a plain line that holds no focus.
typedef _Item = ({
  String key,
  String label,
  String? game,
  String? place,
  bool stack,
  bool laidOut,
});

_Item _line(String key) => (
  key: key,
  label: key,
  game: null,
  place: null,
  stack: false,
  laidOut: false,
);

_Item _row(String key, String label, {String game = 'g', String? place}) => (
  key: key,
  label: label,
  game: game,
  place: place,
  stack: false,
  laidOut: false,
);

_Item _stack(String key, String label, {String game = 'g', String? place}) => (
  key: key,
  label: label,
  game: game,
  place: place,
  stack: true,
  laidOut: false,
);

_Item _laidOut(String key, String label, {String game = 'g'}) => (
  key: key,
  label: label,
  game: game,
  place: null,
  stack: false,
  laidOut: true,
);

/// One form of a game's item, as an entry's row is.
class _Row extends StatelessWidget {
  const _Row(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Material(
    child: InkWell(
      onTap: () {},
      child: SizedBox(height: 48, child: Text(label)),
    ),
  );
}

/// The other form, a widget of another type, as a stack's row is.
class _Stack extends StatelessWidget {
  const _Stack(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: Material(
      child: InkWell(
        onTap: () {},
        child: SizedBox(height: 48, child: Text(label)),
      ),
    ),
  );
}

/// A form with two controls, the first built at layout, inside a
/// [LayoutBuilder], as a cover tile's cover is, and the second built at once,
/// as its expansions badge is (#711). The second's focus node is attached
/// first.
class _LaidOut extends StatelessWidget {
  const _LaidOut(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Material(
    child: Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, _) => InkWell(
              onTap: () {},
              child: SizedBox(height: 48, child: Text(label)),
            ),
          ),
        ),
        InkWell(
          onTap: () {},
          child: SizedBox(height: 48, child: Text('$label badge')),
        ),
      ],
    ),
  );
}

/// Pins how a game's focus follows it from one form of its item to the next
/// (#769, #711): the focused item hands focus to its replacement, and so does
/// the item a covered route will give focus back to, once that route has
/// gone.
void main() {
  late FocusNode other;
  late FocusNode elsewhere;
  late ValueNotifier<List<_Item>> items;

  setUp(() {
    other = FocusNode(debugLabel: 'other');
    elsewhere = FocusNode(debugLabel: 'elsewhere');
    items = ValueNotifier([]);
  });

  tearDown(() {
    other.dispose();
    elsewhere.dispose();
    items.dispose();
  });

  /// A page with a button above the list, so that the page's focus history
  /// holds something besides the game's item, as a real page's does.
  Future<void> show(WidgetTester tester, List<_Item> initial) async {
    items.value = initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Row(
                  children: [
                    TextButton(
                      focusNode: other,
                      onPressed: () {},
                      child: const Text('other'),
                    ),
                    TextButton(
                      focusNode: elsewhere,
                      onPressed: () {},
                      child: const Text('elsewhere'),
                    ),
                  ],
                ),
              ),
              BgeFocusHandoffScope(
                child: SliverMainAxisGroup(
                  slivers: [
                    ValueListenableBuilder<List<_Item>>(
                      valueListenable: items,
                      builder: (_, items, _) => BgeKeyedSliverList<_Item>(
                        items: items,
                        keyOf: (item) => ValueKey(item.key),
                        itemBuilder: (_, item) => switch (item.game) {
                          null => SizedBox(height: 48, child: Text(item.label)),
                          final game => BgeFocusHandoff(
                            identity: game,
                            place: item.place,
                            child: item.laidOut
                                ? _LaidOut(item.label)
                                : item.stack
                                ? _Stack(item.label)
                                : _Row(item.label),
                          ),
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  FocusNode control(WidgetTester tester, String label) =>
      Focus.of(tester.element(find.text(label)));

  /// Focuses the button above the list, then [label]'s item.
  Future<void> focus(WidgetTester tester, String label) async {
    other.requestFocus();
    await tester.pump();
    control(tester, label).requestFocus();
    await tester.pump();
    expect(control(tester, label).hasPrimaryFocus, isTrue);
  }

  BuildContext pageContext(WidgetTester tester) =>
      tester.element(find.text('other'));

  group(
    'hands focus to the replacement when the focused item changes form',
    () {
      final cases = <(String, List<_Item>, List<_Item>)>[
        (
          'in its place',
          [_line('a'), _row('row-g', 'Wingspan')],
          [_line('a'), _stack('stack-g', 'Wingspan copies')],
        ),
        (
          'moving up the list',
          [_line('a'), _line('b'), _line('c'), _row('row-g', 'Wingspan')],
          [
            _line('a'),
            _row('nested-g', 'Wingspan nested', place: 'a'),
            _line('b'),
            _line('c'),
          ],
        ),
        (
          'moving down the list',
          [
            _line('a'),
            _row('nested-g', 'Wingspan', place: 'a'),
            _line('b'),
            _line('c'),
          ],
          [_line('a'), _line('b'), _line('c'), _row('row-g', 'Wingspan top')],
        ),
      ];
      for (final (name, before, after) in cases) {
        testWidgets(name, (tester) async {
          await show(tester, before);
          await focus(tester, 'Wingspan');

          items.value = after;
          await tester.pump();

          final replacement = after.last.game == null
              ? after[1].label
              : after.last.label;
          // In the frame that replaced the item: no frame of focus elsewhere.
          expect(control(tester, replacement).hasPrimaryFocus, isTrue);
          await tester.pumpAndSettle();
          expect(control(tester, replacement).hasPrimaryFocus, isTrue);
        });
      }
    },
  );

  testWidgets("hands focus to the replacement's first control in the tree, "
      'though a later one was attached first', (tester) async {
    await show(tester, [_line('a'), _row('row-g', 'Wingspan')]);
    await focus(tester, 'Wingspan');

    items.value = [_line('a'), _laidOut('laid-g', 'Wingspan cover')];
    await tester.pumpAndSettle();

    expect(control(tester, 'Wingspan cover').hasPrimaryFocus, isTrue);
  });

  testWidgets("hands focus to the replacement's control in the place of the "
      'one that had it', (tester) async {
    await show(tester, [_line('a'), _laidOut('laid-g', 'Wingspan')]);
    await focus(tester, 'Wingspan badge');

    items.value = [_line('a'), _laidOut('laid-g-2', 'Wingspan again')];
    await tester.pumpAndSettle();

    expect(control(tester, 'Wingspan again badge').hasPrimaryFocus, isTrue);
  });

  testWidgets('hands focus to the first control when the replacement has '
      "none in the focused one's place", (tester) async {
    await show(tester, [_line('a'), _laidOut('laid-g', 'Wingspan')]);
    await focus(tester, 'Wingspan badge');

    items.value = [_line('a'), _row('row-g', 'Wingspan row')];
    await tester.pumpAndSettle();

    expect(control(tester, 'Wingspan row').hasPrimaryFocus, isTrue);
  });

  testWidgets('hands focus to the copy under the same base game', (
    tester,
  ) async {
    // The copy under the other base game comes first, so it is built first.
    await show(tester, [
      _line('p2'),
      _row('row-g-p2', 'Wingspan under p2', place: 'p2'),
      _line('p1'),
      _row('row-g-p1', 'Wingspan under p1', place: 'p1'),
    ]);
    await focus(tester, 'Wingspan under p1');

    items.value = [
      _line('p2'),
      _stack('stack-g-p2', 'Wingspan copies under p2', place: 'p2'),
      _line('p1'),
      _stack('stack-g-p1', 'Wingspan copies under p1', place: 'p1'),
    ];
    await tester.pump();

    expect(control(tester, 'Wingspan copies under p1').hasPrimaryFocus, isTrue);
  });

  testWidgets('hands focus to a copy in another place when its own has none', (
    tester,
  ) async {
    await show(tester, [
      _line('p2'),
      _row('row-g-p2', 'Wingspan under p2', place: 'p2'),
      _line('p1'),
      _row('row-g-p1', 'Wingspan under p1', place: 'p1'),
    ]);
    await focus(tester, 'Wingspan under p1');

    // The base game p1 has gone, and the copy under it with it.
    items.value = [
      _line('p2'),
      _row('row-g-p2', 'Wingspan under p2', place: 'p2'),
    ];
    await tester.pump();

    expect(control(tester, 'Wingspan under p2').hasPrimaryFocus, isTrue);
  });

  testWidgets('does nothing when the leaving item had no focus', (
    tester,
  ) async {
    await show(tester, [_line('a'), _row('row-g', 'Wingspan')]);
    // Focus is on the page itself, where a hand-off would be free to take
    // it.
    final page = FocusManager.instance.primaryFocus;
    expect(page, isA<FocusScopeNode>());

    items.value = [_line('a'), _stack('stack-g', 'Wingspan copies')];
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, page);
    expect(control(tester, 'Wingspan copies').hasFocus, isFalse);
  });

  group("hands the pop's restore to the replacement", () {
    for (final escape in [false, true]) {
      testWidgets(escape ? 'closed by Escape' : 'closed by Navigator.pop', (
        tester,
      ) async {
        await show(tester, [_line('a'), _row('row-g', 'Wingspan')]);
        await focus(tester, 'Wingspan');

        late BuildContext above;
        final button = FocusNode(debugLabel: 'above');
        addTearDown(button.dispose);
        Navigator.of(pageContext(tester)).push(
          MaterialPageRoute<void>(
            barrierDismissible: escape,
            builder: (context) {
              above = context;
              return Scaffold(
                body: TextButton(
                  focusNode: button,
                  onPressed: () {},
                  child: const Text('above'),
                ),
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        // A focused button takes Escape for itself, so Escape is pressed
        // with focus on the route.
        if (!escape) {
          button.requestFocus();
          await tester.pump();
        }

        items.value = [_line('a'), _stack('stack-g', 'Wingspan copies')];
        await tester.pump();

        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          Navigator.of(above).pop();
        }
        await tester.pumpAndSettle();

        expect(find.text('above'), findsNothing);
        expect(control(tester, 'Wingspan copies').hasPrimaryFocus, isTrue);
      });
    }
  });

  testWidgets('keeps the game focused last when an item focused before it '
      'leaves too', (tester) async {
    await show(tester, [
      _row('row-h', 'Azul', game: 'h'),
      _row('row-g', 'Wingspan'),
    ]);
    // The page's history: other, then Azul, then Wingspan.
    await focus(tester, 'Azul');
    control(tester, 'Wingspan').requestFocus();
    await tester.pump();

    late BuildContext above;
    Navigator.of(pageContext(tester)).push(
      MaterialPageRoute<void>(
        builder: (context) {
          above = context;
          return const Text('above');
        },
      ),
    );
    await tester.pumpAndSettle();

    // Wingspan changes form, then Azul, the item the pop would land on
    // instead.
    items.value = [
      _row('row-h', 'Azul', game: 'h'),
      _stack('stack-g', 'Wingspan copies'),
    ];
    await tester.pump();
    items.value = [
      _stack('stack-h', 'Azul copies', game: 'h'),
      _stack('stack-g', 'Wingspan copies'),
    ];
    await tester.pump();

    Navigator.of(above).pop();
    await tester.pumpAndSettle();

    expect(control(tester, 'Wingspan copies').hasPrimaryFocus, isTrue);
  });

  testWidgets('leaves focus the user has moved since the pop', (tester) async {
    await show(tester, [_line('a'), _row('row-g', 'Wingspan')]);
    await focus(tester, 'Wingspan');

    late BuildContext above;
    Navigator.of(pageContext(tester)).push(
      MaterialPageRoute<void>(
        builder: (context) {
          above = context;
          return const Text('above');
        },
      ),
    );
    await tester.pumpAndSettle();
    items.value = [_line('a'), _stack('stack-g', 'Wingspan copies')];
    await tester.pump();

    Navigator.of(above).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // The user moves focus while the page above is still leaving.
    elsewhere.requestFocus();
    await tester.pumpAndSettle();

    expect(find.text('above'), findsNothing);
    expect(elsewhere.hasPrimaryFocus, isTrue);
  });

  group("hands a pop-up's restore to the replacement", () {
    for (final escape in [false, true]) {
      testWidgets(escape ? 'closed by Escape' : 'closed by Navigator.pop', (
        tester,
      ) async {
        await show(tester, [_line('a'), _row('row-g', 'Wingspan')]);
        await focus(tester, 'Wingspan');

        late BuildContext dialog;
        unawaited(
          showDialog<void>(
            context: pageContext(tester),
            builder: (context) {
              dialog = context;
              return const AlertDialog(content: Text('picker'));
            },
          ),
        );
        await tester.pumpAndSettle();

        items.value = [_line('a'), _stack('stack-g', 'Wingspan copies')];
        await tester.pump();

        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          Navigator.of(dialog).pop();
        }
        await tester.pumpAndSettle();

        expect(find.text('picker'), findsNothing);
        expect(control(tester, 'Wingspan copies').hasPrimaryFocus, isTrue);
      });
    }
  });

  group('drops a pending hand-off when no replacement arrives', () {
    for (final popUp in [false, true]) {
      testWidgets(popUp ? 'under a pop-up' : 'under a page', (tester) async {
        await show(tester, [_line('a'), _row('row-g', 'Wingspan')]);
        await focus(tester, 'Wingspan');

        Future<void> openAndClose({bool gameLeaves = false}) async {
          late BuildContext above;
          Widget build(BuildContext context) {
            above = context;
            return const Text('above');
          }

          unawaited(
            popUp
                ? showDialog<void>(context: pageContext(tester), builder: build)
                : Navigator.of(pageContext(tester))
                      .push(MaterialPageRoute<void>(builder: build)),
          );
          await tester.pumpAndSettle();
          if (gameLeaves) {
            // The game leaves while it is covered, with no other form.
            items.value = [_line('a')];
            await tester.pump();
          }
          Navigator.of(above).pop();
          await tester.pumpAndSettle();
        }

        await openAndClose(gameLeaves: true);
        // The pop gives focus to what the page focused before.
        expect(other.hasPrimaryFocus, isTrue);

        // The game comes back too late to be handed anything, by this pop
        // or the next.
        items.value = [_line('a'), _stack('stack-g', 'Wingspan copies')];
        await tester.pumpAndSettle();
        expect(other.hasPrimaryFocus, isTrue);
        await openAndClose();

        expect(other.hasPrimaryFocus, isTrue);
        expect(control(tester, 'Wingspan copies').hasFocus, isFalse);
      });
    }
  });

  group('carries focus a mouse gave, hidden until a key press', () {
    /// The game's form: `stack`, a stack of two; `single` or `third`, one
    /// entry's cover, each under its own key; or null once it has gone.
    late ValueNotifier<String?> form;
    late TestGesture mouse;
    const away = Offset(700, 500);

    setUp(() => form = ValueNotifier('stack'));
    tearDown(() => form.dispose());

    /// The game's cover, a stack of two or one entry's, under the button
    /// above the list, which has had focus.
    Future<void> showCover(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: TextButton(
                    focusNode: other,
                    onPressed: () {},
                    child: const Text('other'),
                  ),
                ),
                BgeFocusHandoffScope(
                  child: SliverMainAxisGroup(
                    slivers: [
                      ValueListenableBuilder<String?>(
                        valueListenable: form,
                        builder: (_, form, _) => BgeKeyedSliverList<String>(
                          items: [?form],
                          keyOf: ValueKey.new,
                          itemBuilder: (_, form) => BgeFocusHandoff(
                            identity: 'g',
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: BgeCoverTile(
                                label: form == 'stack'
                                    ? 'Azul, 2 copies'
                                    : 'Azul',
                                stackCount: form == 'stack' ? 2 : null,
                                onTap: () {},
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: away);
      addTearDown(mouse.removePointer);
      // So the page's focus history holds something besides the cover.
      other.requestFocus();
      await tester.pump();
    }

    Finder cover(String key) => find.byKey(ValueKey(key));

    /// Clicks the cover [key], then moves the mouse away, so no hover is
    /// drawn.
    Future<void> click(WidgetTester tester, String key) async {
      final at = tester.getCenter(
        find.descendant(of: cover(key), matching: find.byType(BgeCoverTile)),
      );
      await mouse.moveTo(at);
      await mouse.down(at);
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.up();
      await mouse.moveTo(away);
      await tester.pumpAndSettle();
    }

    BgeFocusRing ring(WidgetTester tester, String key) =>
        tester.widget<BgeFocusRing>(
          find.descendant(of: cover(key), matching: find.byType(BgeFocusRing)),
        );

    /// Whether the cover [key]'s ink draws a tint: any of its features
    /// painted with some strength. Once settled, with the mouse away, only
    /// the focus highlight is left to paint.
    bool tinted(WidgetTester tester, String key) {
      var strength = 0.0;
      expect(
        tester.renderObject(
          find.descendant(of: cover(key), matching: find.byType(Material)),
        ),
        paints..everything((method, arguments) {
          for (final argument in arguments) {
            if (argument is Paint && argument.color.a > strength) {
              strength = argument.color.a;
            }
          }
          return true;
        }),
      );
      return strength > 0;
    }

    /// Whether the cover [key] has focus, and its ring and its ink's tint
    /// are drawn.
    ({bool focused, bool ringed, bool tinted}) state(
      WidgetTester tester,
      String key,
    ) {
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.descendant(
                of: cover(key),
                matching: find.byType(BgeFocusRing),
              ),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return (
        focused: _focusIsWithin(tester, cover(key)),
        ringed: (box.decoration as BoxDecoration).border != null,
        tinted: tinted(tester, key),
      );
    }

    /// Tabs away from the cover [key] and back, as a keyboard user would.
    Future<void> tabAwayAndBack(WidgetTester tester, String key) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(state(tester, key).focused, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('when the focused item changes form', (tester) async {
      await showCover(tester);
      await click(tester, 'stack');
      expect(state(tester, 'stack'), (
        focused: true,
        ringed: false,
        tinted: false,
      ));
      // A mouse leaves the highlight mode at the keyboard's on a desktop.
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );

      form.value = 'single';
      await tester.pumpAndSettle();

      expect(state(tester, 'single'), (
        focused: true,
        ringed: false,
        tinted: false,
      ));
      expect(ring(tester, 'single').suppressed, isTrue);

      // The ring comes back at the key press; the tint, as for any control,
      // from the control's next focus (`BgePointerFocus`).
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(state(tester, 'single').ringed, isTrue);
      await tabAwayAndBack(tester, 'single');

      expect(state(tester, 'single'), (
        focused: true,
        ringed: true,
        tinted: true,
      ));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('leaves focus the user moves while the replacement rebuilds', (
      tester,
    ) async {
      await showCover(tester);
      await click(tester, 'stack');

      form.value = 'single';
      await tester.pump();
      // The replacement was built for keyboard focus, so focus waits a frame
      // on the page; the user moves it in that frame.
      expect(state(tester, 'single').focused, isFalse);
      other.requestFocus();
      await tester.pumpAndSettle();

      expect(other.hasPrimaryFocus, isTrue);
      expect(state(tester, 'single').focused, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    /// The page's focus scope, where focus waits while a replacement
    /// rebuilds.
    FocusNode page(WidgetTester tester) =>
        FocusScope.of(tester.element(find.text('other')));

    testWidgets('to the newest replacement when the game changes form again '
        'while focus waits', (tester) async {
      await showCover(tester);
      await click(tester, 'stack');

      form.value = 'single';
      await tester.pump();
      // Focus waits a frame on the page while the replacement rebuilds; the
      // game changes form again in that frame.
      expect(FocusManager.instance.primaryFocus, page(tester));
      form.value = 'third';
      await tester.pumpAndSettle();

      expect(state(tester, 'third'), (
        focused: true,
        ringed: false,
        tinted: false,
      ));
      expect(ring(tester, 'third').suppressed, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('and draws it when a key is pressed while focus waits', (
      tester,
    ) async {
      await showCover(tester);
      await click(tester, 'stack');

      form.value = 'single';
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, page(tester));
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(state(tester, 'single'), (
        focused: true,
        ringed: true,
        tinted: true,
      ));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('to the newest replacement when the game changes form again '
        "while a pop-up's restore waits", (tester) async {
      await showCover(tester);
      await click(tester, 'stack');
      late BuildContext dialog;
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('other')),
          builder: (context) {
            dialog = context;
            return const AlertDialog(content: Text('picker'));
          },
        ),
      );
      await tester.pumpAndSettle();
      form.value = 'single';
      await tester.pump();

      Navigator.of(dialog).pop();
      // Until the restore parks focus on the page for the replacement to
      // rebuild; the game changes form again in that frame.
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump();
        if (FocusManager.instance.primaryFocus == page(tester)) break;
      }
      expect(FocusManager.instance.primaryFocus, page(tester));
      form.value = 'third';
      await tester.pumpAndSettle();

      expect(find.text('picker'), findsNothing);
      expect(state(tester, 'third'), (
        focused: true,
        ringed: false,
        tinted: false,
      ));
      expect(ring(tester, 'third').suppressed, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets("a keyboard's focus stays drawn, and moves at once", (
      tester,
    ) async {
      await showCover(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(state(tester, 'stack'), (
        focused: true,
        ringed: true,
        tinted: true,
      ));

      form.value = 'single';
      await tester.pump();
      // In the frame that replaced the item.
      expect(state(tester, 'single').focused, isTrue);
      await tester.pumpAndSettle();

      expect(state(tester, 'single'), (
        focused: true,
        ringed: true,
        tinted: true,
      ));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    for (final keyPressed in [false, true]) {
      testWidgets(
        keyPressed
            ? 'to the restore, unless a key is pressed while it is covered'
            : "to the pop's restore",
        (tester) async {
          await showCover(tester);
          await click(tester, 'stack');
          late BuildContext above;
          Navigator.of(tester.element(find.text('other'))).push(
            MaterialPageRoute<void>(
              builder: (context) {
                above = context;
                return const Text('above');
              },
            ),
          );
          await tester.pumpAndSettle();
          form.value = 'single';
          await tester.pump();
          if (keyPressed) {
            await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
            await tester.pump();
          }

          Navigator.of(above).pop();
          await tester.pumpAndSettle();

          // A key press while it waited is the keyboard's focus: drawn.
          expect(state(tester, 'single'), (
            focused: true,
            ringed: keyPressed,
            tinted: keyPressed,
          ));
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }

    for (final listGoes in [false, true]) {
      testWidgets(
        listGoes
            ? 'and stops listening for keys when the list goes while it waits'
            : 'and stops listening for keys when the hand-off is dropped',
        (tester) async {
          await showCover(tester);
          await click(tester, 'stack');
          late BuildContext above;
          Navigator.of(tester.element(find.text('other'))).push(
            MaterialPageRoute<void>(
              builder: (context) {
                above = context;
                return const Text('above');
              },
            ),
          );
          await tester.pumpAndSettle();
          // The game leaves under the page with no other form.
          form.value = null;
          await tester.pump();

          if (listGoes) {
            await tester.pumpWidget(
              MaterialApp(
                theme: BgeTheme.light(),
                home: const SizedBox.shrink(),
              ),
            );
          } else {
            Navigator.of(above).pop();
            await tester.pumpAndSettle();
            expect(other.hasPrimaryFocus, isTrue);
          }
          // A handler left behind would set a disposed flag, which throws.
          await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();

          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }
  });
}

/// Whether the primary focus is on the widget [finder] finds, or inside it.
bool _focusIsWithin(WidgetTester tester, Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final target = tester.element(finder);
  var within = identical(context, target);
  context.visitAncestorElements((ancestor) {
    within = within || identical(ancestor, target);
    return !within;
  });
  return within;
}
