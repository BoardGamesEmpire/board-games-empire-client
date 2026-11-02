import 'dart:async' show unawaited;
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _spaceXxl = BgeTokens.spaceXxlValue;
const _coverWidth = 100.0;
const _coverCount = 10;

/// Ten covers with their gaps: wider than the narrow window, and narrower than
/// a wide enough one.
const _rowWidth =
    _coverCount * _coverWidth + (_coverCount - 1) * BgeTokens.spaceMdValue;

const _narrow = Size(400, 600);
const _middling = Size(800, 600);
const _wide = Size(1000, 600);
const _roomForAll = Size(1400, 600);

Key _coverKey(int index) => Key('cover.$index');
const _actionKey = Key('action');
const _placeholderKey = Key('placeholder');

/// A row of tappable covers, each [_coverWidth] wide.
List<Widget> _covers({
  void Function(int index)? onTap,
  Map<int, FocusNode> focusNodes = const {},
}) => [
  for (var i = 0; i < _coverCount; i++)
    SizedBox(
      key: _coverKey(i),
      width: _coverWidth,
      height: _coverWidth,
      child: InkWell(
        focusNode: focusNodes[i],
        onTap: () => onTap?.call(i),
        child: Text('cover $i'),
      ),
    ),
];

Widget _app(Widget shelf, {TextDirection direction = TextDirection.ltr}) =>
    MaterialApp(
      theme: BgeTheme.light(),
      home: Directionality(
        textDirection: direction,
        child: Scaffold(body: shelf),
      ),
    );

Widget _shelf({
  List<Widget>? children,
  List<Widget> actions = const [],
  Widget? placeholder,
  Widget? note,
  bool equalHeights = false,
  Object? resetToken,
  Key? headingKey,
}) => BgeShelf(
  heading: 'Heading',
  previousLabel: 'Previous',
  nextLabel: 'Next',
  actions: actions,
  placeholder: placeholder,
  note: note,
  equalHeights: equalHeights,
  resetToken: resetToken,
  headingKey: headingKey,
  children: children ?? _covers(),
);

/// Pumps a shelf and the frame its measurement asks for: the scroll view's
/// first metrics arrive after the frame that laid it out.
Future<void> _show(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

ScrollPosition _rowOf(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(BgeShelf),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

Finder get _previous => find.byKey(BgeShelf.previousKey);
Finder get _next => find.byKey(BgeShelf.nextKey);

SemanticsData _semanticsOf(WidgetTester tester, Finder button) =>
    tester.getSemantics(button).getSemanticsData();

void _performOn(WidgetTester tester, Finder button, SemanticsAction action) {
  final node = tester.getSemantics(button);
  node.owner!.performAction(node.id, action);
}

/// Tabs until [node] has the focus, failing rather than looping for ever.
Future<void> _tabTo(WidgetTester tester, FocusNode node) async {
  for (var i = 0; i < 30 && !node.hasPrimaryFocus; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(node.hasPrimaryFocus, isTrue, reason: 'never reached by tabbing');
}

FocusNode _focusOf(WidgetTester tester, Finder button) => Focus.of(
  tester.element(find.descendant(of: button, matching: find.byType(Icon))),
);

void main() {
  group('overflow', () {
    testWidgets('with room for every child there are no buttons', (
      tester,
    ) async {
      useViewSize(tester, _roomForAll);
      await _show(tester, _app(_shelf()));

      expect(_previous, findsNothing);
      expect(_next, findsNothing);
      expect(find.byKey(_coverKey(0)), findsOneWidget);
    });

    testWidgets(
      'overflowing: both buttons, previous reports disabled at the start',
      (tester) async {
        useViewSize(tester, _narrow);
        await _show(tester, _app(_shelf()));

        expect(_previous, findsOneWidget);
        expect(_next, findsOneWidget);
        expect(
          _semanticsOf(tester, _previous).flagsCollection.isEnabled,
          Tristate.isFalse,
        );
        expect(
          _semanticsOf(tester, _next).flagsCollection.isEnabled,
          Tristate.isTrue,
        );
      },
    );

    testWidgets('growing the window past the row removes the buttons', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));
      expect(_next, findsOneWidget);

      useViewSize(tester, _roomForAll);
      await tester.pumpAndSettle();

      expect(_previous, findsNothing);
      expect(_next, findsNothing);

      useViewSize(tester, _narrow);
      await tester.pumpAndSettle();

      expect(_next, findsOneWidget);
    });

    testWidgets('shrinking it while scrolled clamps and recomputes the end '
        'state', (tester) async {
      useViewSize(tester, _middling);
      await _show(tester, _app(_shelf()));

      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, _rowWidth - _middling.width);
      expect(
        _semanticsOf(tester, _next).flagsCollection.isEnabled,
        Tristate.isFalse,
      );

      // Wider: less to scroll, so the offset comes back with the end.
      useViewSize(tester, _wide);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, _rowWidth - _wide.width);
      expect(
        _semanticsOf(tester, _next).flagsCollection.isEnabled,
        Tristate.isFalse,
      );

      // Narrower: the same offset is no longer the end.
      useViewSize(tester, _narrow);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, _rowWidth - _wide.width);
      expect(
        _semanticsOf(tester, _next).flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      expect(
        _semanticsOf(tester, _previous).flagsCollection.isEnabled,
        Tristate.isTrue,
      );
    });

    testWidgets('text growing while scrolled recomputes the buttons', (
      tester,
    ) async {
      useViewSize(tester, _middling);

      // Text, not a fixed width, so that the row grows with the scale.
      Widget at(double scale) => MediaQuery(
        data: MediaQueryData(
          size: _middling,
          textScaler: TextScaler.linear(scale),
        ),
        child: _app(
          _shelf(children: [for (var i = 0; i < 6; i++) Text('cover $i ' * 2)]),
        ),
      );

      await _show(tester, at(1));
      final fitted = _rowOf(tester).maxScrollExtent;
      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, fitted);
      expect(
        _semanticsOf(tester, _next).flagsCollection.isEnabled,
        Tristate.isFalse,
      );

      await tester.pumpWidget(at(2));
      await tester.pumpAndSettle();

      expect(_rowOf(tester).maxScrollExtent, greaterThan(fitted));
      expect(_rowOf(tester).pixels, fitted);
      expect(
        _semanticsOf(tester, _next).flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('moving by button', () {
    testWidgets('next moves one view less spaceXxl, capped at the end', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));
      final step = _narrow.width - _spaceXxl;
      final end = _rowWidth - _narrow.width;

      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, math.min(step, end));

      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, math.min(step * 2, end));

      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, end);

      await tester.tap(_previous);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, end - step);
    });

    testWidgets('reduced motion: next jumps', (tester) async {
      useViewSize(tester, _narrow);
      await _show(
        tester,
        MediaQuery(
          data: const MediaQueryData(size: _narrow, disableAnimations: true),
          child: _app(_shelf()),
        ),
      );

      await tester.tap(_next);

      // No frames: a jump, and not an animation of no length.
      expect(_rowOf(tester).pixels, _narrow.width - _spaceXxl);
    });

    testWidgets('it animates otherwise', (tester) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));

      await tester.tap(_next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final midway = _rowOf(tester).pixels;
      expect(midway, greaterThan(0));
      expect(midway, lessThan(_narrow.width - _spaceXxl));
      await tester.pumpAndSettle();
    });

    testWidgets('right to left: previous is at the start edge and moves back', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf(), direction: TextDirection.rtl));

      expect(
        tester.getCenter(_previous).dx,
        greaterThan(tester.getCenter(_next).dx),
      );
      // The row starts at the right, and moving on brings in what is to its
      // left, so each chevron points the way its button moves the row.
      expect(Icons.chevron_left.matchTextDirection, isTrue);
      expect(Icons.chevron_right.matchTextDirection, isTrue);
      expect(tester.getTopRight(find.byKey(_coverKey(0))).dx, _narrow.width);

      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, _narrow.width - _spaceXxl);
      expect(
        tester.getTopRight(find.byKey(_coverKey(0))).dx,
        greaterThan(_narrow.width),
      );

      await tester.tap(_previous);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, 0);
    });

    testWidgets('a change of resetToken returns to the start', (tester) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf(resetToken: 1)));
      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, isNot(0));

      await tester.pumpWidget(_app(_shelf(resetToken: 1)));
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, isNot(0));

      await tester.pumpWidget(_app(_shelf(resetToken: 2)));
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a change of resetToken stops a move under way', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf(resetToken: 1)));
      await tester.tap(_next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pumpWidget(_app(_shelf(resetToken: 2)));
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, 0);
    });
  });

  group('at an end', () {
    testWidgets(
      'at the end next stays focused, ignores a press, and reports disabled',
      (tester) async {
        useViewSize(tester, _narrow);
        await _show(tester, _app(_shelf()));
        final end = _rowWidth - _narrow.width;

        final focus = _focusOf(tester, _next);
        await _tabTo(tester, focus);
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
        }
        expect(_rowOf(tester).pixels, end);
        expect(focus.hasPrimaryFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        await tester.tap(_next);
        await tester.pumpAndSettle();

        expect(_rowOf(tester).pixels, end);
        expect(focus.hasPrimaryFocus, isTrue);
        expect(_focusOf(tester, _next), same(focus));
        final data = _semanticsOf(tester, _next);
        expect(data.flagsCollection.isEnabled, Tristate.isFalse);
        // Focusable, and focused: the node a screen reader lands on.
        expect(data.flagsCollection.isFocused, Tristate.isTrue);
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.label, 'Next');
        expect(data.tooltip, isEmpty);
      },
    );

    testWidgets('the disabled end offers no tap, and the other end does', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));

      expect(
        _semanticsOf(tester, _previous).hasAction(SemanticsAction.tap),
        isFalse,
      );
      expect(
        _semanticsOf(tester, _next).hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(_semanticsOf(tester, _previous).label, 'Previous');

      _performOn(tester, _next, SemanticsAction.tap);
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, _narrow.width - _spaceXxl);
      expect(
        _semanticsOf(tester, _previous).hasAction(SemanticsAction.tap),
        isTrue,
      );
    });

    testWidgets('a screen reader can move focus to a button at its end', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));
      expect(
        _semanticsOf(tester, _previous).hasAction(SemanticsAction.focus),
        isTrue,
      );

      _performOn(tester, _previous, SemanticsAction.focus);
      await tester.pumpAndSettle();

      expect(_focusOf(tester, _previous).hasPrimaryFocus, isTrue);
      expect(
        _semanticsOf(tester, _previous).flagsCollection.isFocused,
        Tristate.isTrue,
      );
    });

    testWidgets('a button is one node, the same as a plain IconButton', (
      tester,
    ) async {
      // What the button's own node says away from an end, measured against the
      // framework's, so that replacing it can't quietly lose something. The
      // name alone differs: a label here, for VoiceOver's sake.
      useViewSize(tester, _narrow);
      await _show(
        tester,
        _app(
          _shelf(
            actions: [
              IconButton(
                key: _actionKey,
                tooltip: 'Next',
                icon: const Icon(Icons.chevron_right),
                onPressed: () {},
              ),
            ],
          ),
        ),
      );

      final ours = _semanticsOf(tester, _next);
      final plain = _semanticsOf(tester, find.byKey(_actionKey));

      expect(ours.flagsCollection, plain.flagsCollection);
      expect(ours.actions, plain.actions);
      expect(ours.label, plain.tooltip);
      expect(ours.tooltip, isEmpty);
    }, variant: TargetPlatformVariant.all());

    testWidgets('VoiceOver can land on a button at its end, and pressing up to '
        'the end keeps it there', (tester) async {
      // The engine's rule for an accessibility element on iOS, `isFocusable` in
      // SemanticsObject.mm: a label, value or hint, or an action that doesn't
      // scroll. A tooltip and the focusable flag don't count.
      bool canLand(SemanticsData data) =>
          data.label.isNotEmpty ||
          data.value.isNotEmpty ||
          data.hint.isNotEmpty ||
          SemanticsAction.values.any(
            (action) =>
                data.hasAction(action) &&
                !kVerticalScrollActions.contains(action) &&
                !kHorizontalScrollActions.contains(action),
          );

      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));

      final atStart = _semanticsOf(tester, _previous);
      expect(atStart.flagsCollection.isEnabled, Tristate.isFalse);
      expect(canLand(atStart), isTrue);
      expect(atStart.label, 'Previous');

      for (var i = 0; i < 3; i++) {
        _performOn(tester, _next, SemanticsAction.tap);
        await tester.pumpAndSettle();
      }

      expect(_rowOf(tester).pixels, _rowWidth - _narrow.width);
      final atEnd = _semanticsOf(tester, _next);
      expect(atEnd.flagsCollection.isEnabled, Tristate.isFalse);
      expect(canLand(atEnd), isTrue);
      expect(atEnd.label, 'Next');
      // Read once: iOS joins a label and a tooltip.
      expect(atEnd.tooltip, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('hovering shows the name, at an end and away from one', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      for (final (button, name) in [(_previous, 'Previous'), (_next, 'Next')]) {
        expect(find.text(name), findsNothing);
        await mouse.moveTo(tester.getCenter(button));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text(name), findsOneWidget);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle(const Duration(seconds: 1));
      }
    });

    testWidgets('it is drawn in the theme\'s disabled colour', (tester) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));

      Color? iconColor(Finder button) => IconTheme.of(
        tester.element(
          find.descendant(of: button, matching: find.byType(Icon)),
        ),
      ).color;

      final disabled = BgeTheme.light().disabledColor;
      expect(iconColor(_previous), disabled);
      expect(iconColor(_next), isNot(disabled));
    });

    testWidgets('it answers no hover or press, and shows focus as ever', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));

      final atEnd = tester.widget<IconButton>(_previous).style!;
      expect(atEnd.overlayColor!.resolve({WidgetState.hovered})!.a, 0);
      expect(atEnd.overlayColor!.resolve({WidgetState.pressed})!.a, 0);
      // Null falls through to the button's default, which is what keyboard
      // users see on every other button.
      expect(atEnd.overlayColor!.resolve({WidgetState.focused}), isNull);
      expect(atEnd.mouseCursor!.resolve(const {}), SystemMouseCursors.basic);
      expect(tester.widget<IconButton>(_next).style, isNull);
    });
  });

  group('moving by hand', () {
    testWidgets('a touch swipe moves the row', (tester) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));

      await tester.drag(find.byKey(_coverKey(1)), const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, greaterThan(0));
    });

    testWidgets('a mouse drag moves the row and does not tap a child', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      final tapped = <int>[];
      await _show(tester, _app(_shelf(children: _covers(onTap: tapped.add))));

      await tester.drag(
        find.byKey(_coverKey(1)),
        const Offset(-200, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, greaterThan(0));
      expect(tapped, isEmpty);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('a trackpad pan moves the row', (tester) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));

      final pan = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pan.panZoomStart(tester.getCenter(find.byKey(_coverKey(1))));
      await pan.panZoomUpdate(
        tester.getCenter(find.byKey(_coverKey(1))),
        pan: const Offset(-200, 0),
      );
      await pan.panZoomEnd();
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, greaterThan(0));
    });

    testWidgets('a tap still reaches a child', (tester) async {
      useViewSize(tester, _narrow);
      final tapped = <int>[];
      await _show(tester, _app(_shelf(children: _covers(onTap: tapped.add))));

      await tester.tap(find.byKey(_coverKey(1)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_coverKey(2)), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(tapped, [1, 2]);
      expect(_rowOf(tester).pixels, 0);
    });

    group('in a page that scrolls', () {
      final page = ScrollController();
      tearDownAll(page.dispose);

      Widget paged() => _app(
        SingleChildScrollView(
          controller: page,
          child: Column(children: [_shelf(), const SizedBox(height: 2000)]),
        ),
      );

      testWidgets('a vertical wheel over the row goes to the page', (
        tester,
      ) async {
        useViewSize(tester, _narrow);
        await _show(tester, paged());
        final over = tester.getCenter(find.byKey(_coverKey(1)));

        final wheel = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(wheel.hover(over));
        await tester.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
        await tester.pumpAndSettle();

        expect(page.position.pixels, 120);
        expect(_rowOf(tester).pixels, 0);
      }, variant: TargetPlatformVariant.desktop());

      testWidgets('a vertical trackpad pan over the row goes to the page', (
        tester,
      ) async {
        useViewSize(tester, _narrow);
        await _show(tester, paged());
        final over = tester.getCenter(find.byKey(_coverKey(1)));

        final pan = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await pan.panZoomStart(over);
        // The first update settles which of the two scroll views gets the pan.
        await pan.panZoomUpdate(over, pan: const Offset(0, -50));
        await pan.panZoomUpdate(over, pan: const Offset(0, -100));
        await pan.panZoomEnd();
        await tester.pumpAndSettle();

        expect(page.position.pixels, greaterThan(0));
        expect(_rowOf(tester).pixels, 0);
        page.jumpTo(0);
      });

      group('a wheel event with both a dx and a dy', () {
        Future<void> wheel(
          WidgetTester tester,
          Offset delta, {
          Finder? over,
          PointerDeviceKind kind = PointerDeviceKind.mouse,
          void Function({required bool allowPlatformDefault})? onRespond,
        }) async {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              kind: kind,
              position: tester.getCenter(over ?? find.byKey(_coverKey(1))),
              scrollDelta: delta,
              onRespond: onRespond,
            ),
          );
          await tester.pumpAndSettle();
        }

        testWidgets('mostly vertical moves the page by its dy, and leaves the '
            'row put', (tester) async {
          useViewSize(tester, _narrow);
          await _show(tester, paged());

          await wheel(tester, const Offset(2, 8));

          expect(page.position.pixels, 8);
          expect(_rowOf(tester).pixels, 0);
        }, variant: TargetPlatformVariant.desktop());

        testWidgets('it is the same from a trackpad, as the web reports one', (
          tester,
        ) async {
          useViewSize(tester, _narrow);
          await _show(tester, paged());

          await wheel(
            tester,
            const Offset(2, 8),
            kind: PointerDeviceKind.trackpad,
          );

          expect(page.position.pixels, 8);
          expect(_rowOf(tester).pixels, 0);
        });

        testWidgets('it is the same over the gap between two children', (
          tester,
        ) async {
          useViewSize(tester, _narrow);
          await _show(tester, paged());
          final over = Offset(
            tester.getTopRight(find.byKey(_coverKey(1))).dx +
                BgeTokens.spaceMdValue / 2,
            tester.getCenter(find.byKey(_coverKey(1))).dy,
          );
          expect(
            over.dx,
            lessThan(tester.getTopLeft(find.byKey(_coverKey(2))).dx),
          );

          await tester.sendEventToBinding(
            PointerScrollEvent(position: over, scrollDelta: const Offset(2, 8)),
          );
          await tester.pumpAndSettle();

          expect(page.position.pixels, 8);
          expect(_rowOf(tester).pixels, 0);
        });

        testWidgets(
          'a stream with a little dx in some events does not stutter',
          (tester) async {
            useViewSize(tester, _narrow);
            // Low enough on the page to stay under the pointer throughout.
            await _show(
              tester,
              _app(
                SingleChildScrollView(
                  controller: page,
                  child: Column(
                    children: [
                      const SizedBox(height: 300),
                      _shelf(),
                      const SizedBox(height: 2000),
                    ],
                  ),
                ),
              ),
            );

            for (var i = 0; i < 12; i++) {
              await wheel(tester, Offset(i % 3 == 0 ? 1 : 0, 12));
            }

            expect(page.position.pixels, 144);
            expect(_rowOf(tester).pixels, 0);
          },
        );

        testWidgets('mostly horizontal still moves the row', (tester) async {
          useViewSize(tester, _narrow);
          await _show(tester, paged());

          await wheel(tester, const Offset(8, 2));

          expect(_rowOf(tester).pixels, 8);
          expect(page.position.pixels, 0);
        });

        testWidgets('as much of one as the other still moves the row', (
          tester,
        ) async {
          useViewSize(tester, _narrow);
          await _show(tester, paged());

          await wheel(tester, const Offset(8, 8));

          expect(_rowOf(tester).pixels, 8);
          expect(page.position.pixels, 0);
        });

        testWidgets('a held shift still moves the row', (tester) async {
          useViewSize(tester, _narrow);
          await _show(tester, paged());

          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await wheel(tester, const Offset(2, 80));
          await wheel(tester, const Offset(0, 80));
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

          // The framework's flip: a mouse wheel's dy moves the row.
          expect(_rowOf(tester).pixels, 160);
          expect(page.position.pixels, 0);
        }, variant: TargetPlatformVariant.desktop());

        testWidgets('with no page around it, the row keeps it', (tester) async {
          useViewSize(tester, _narrow);
          await _show(tester, _app(_shelf()));

          await wheel(tester, const Offset(2, 8));

          expect(_rowOf(tester).pixels, 2);
        });

        testWidgets('with a page that has nowhere to go, the row keeps it', (
          tester,
        ) async {
          useViewSize(tester, _narrow);
          await _show(tester, _app(SingleChildScrollView(child: _shelf())));

          await wheel(tester, const Offset(2, 8));

          expect(_rowOf(tester).pixels, 2);
        });

        testWidgets('at the end of the page it goes nowhere, and the platform '
            'may have it', (tester) async {
          useViewSize(tester, _narrow);
          // Tall enough to scroll, with the row still in view at its end.
          await _show(
            tester,
            _app(
              SingleChildScrollView(
                controller: page,
                child: Column(
                  children: [const SizedBox(height: 500), _shelf()],
                ),
              ),
            ),
          );
          final end = page.position.maxScrollExtent;
          expect(end, greaterThan(0));
          page.jumpTo(end);
          await tester.pumpAndSettle();
          final answers = <bool>[];

          await wheel(
            tester,
            const Offset(2, 8),
            onRespond: ({required allowPlatformDefault}) =>
                answers.add(allowPlatformDefault),
          );

          expect(page.position.pixels, end);
          expect(_rowOf(tester).pixels, 0);
          // As the framework answers when nothing scrolls: an embedded view's
          // host page can have the event.
          expect(answers, [true]);
        });

        testWidgets('it respects a reversed page', (tester) async {
          useViewSize(tester, _narrow);
          await _show(
            tester,
            _app(
              SingleChildScrollView(
                controller: page,
                reverse: true,
                child: Column(
                  children: [const SizedBox(height: 2000), _shelf()],
                ),
              ),
            ),
          );
          // Not so far that the row, at the foot of the page, leaves the screen.
          page.jumpTo(30);
          await tester.pumpAndSettle();
          // A pure vertical event, left to the framework, is the measure.
          await wheel(tester, const Offset(0, 8));
          expect(page.position.pixels, 22);

          await wheel(tester, const Offset(2, 8));

          expect(page.position.pixels, 14);
          expect(_rowOf(tester).pixels, 0);
        });

        testWidgets('moving the page tells the platform to leave it be', (
          tester,
        ) async {
          useViewSize(tester, _narrow);
          await _show(tester, paged());
          final answers = <bool>[];

          await wheel(
            tester,
            const Offset(2, 8),
            onRespond: ({required allowPlatformDefault}) =>
                answers.add(allowPlatformDefault),
          );

          expect(answers, [false]);
        });
      });

      testWidgets('a sideways wheel over the row moves the row', (
        tester,
      ) async {
        useViewSize(tester, _narrow);
        await _show(tester, paged());
        final over = tester.getCenter(find.byKey(_coverKey(1)));

        final wheel = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(wheel.hover(over));
        await tester.sendEventToBinding(wheel.scroll(const Offset(120, 0)));
        await tester.pumpAndSettle();

        expect(_rowOf(tester).pixels, 120);
        expect(page.position.pixels, 0);
      });
    });
  });

  group('focus', () {
    testWidgets('tabbing to an off-screen child scrolls it into view', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      final target = FocusNode();
      addTearDown(target.dispose);
      await _show(
        tester,
        _app(_shelf(children: _covers(focusNodes: {7: target}))),
      );
      expect(tester.getTopLeft(find.byKey(_coverKey(7))).dx, greaterThan(400));

      await _tabTo(tester, target);
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byKey(_coverKey(7)));
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(_narrow.width));
      expect(_rowOf(tester).pixels, greaterThan(0));
    });

    testWidgets('tabbing back reaches a child off the other end', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      final first = FocusNode();
      addTearDown(first.dispose);
      final last = FocusNode();
      addTearDown(last.dispose);
      await _show(
        tester,
        _app(
          _shelf(
            children: _covers(focusNodes: {0: first, _coverCount - 1: last}),
          ),
        ),
      );
      await _tabTo(tester, last);
      await tester.pumpAndSettle();
      expect(_rowOf(tester).pixels, greaterThan(0));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      for (var i = 0; i < _coverCount && !first.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(first.hasPrimaryFocus, isTrue);
      expect(tester.getRect(find.byKey(_coverKey(0))).left, 0);
      expect(_rowOf(tester).pixels, 0);
    });
  });

  group('timing', () {
    testWidgets('a scroll made during a build waits for the frame to finish', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      final scrollInBuild = ValueNotifier<bool>(false);
      addTearDown(scrollInBuild.dispose);
      await _show(
        tester,
        _app(
          _shelf(
            children: [
              ..._covers(),
              ValueListenableBuilder(
                valueListenable: scrollInBuild,
                builder: (context, scroll, _) {
                  if (scroll) Scrollable.of(context).position.jumpTo(50);
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      );
      expect(
        _semanticsOf(tester, _previous).hasAction(SemanticsAction.tap),
        isFalse,
      );

      scrollInBuild.value = true;
      await tester.pump();

      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(_rowOf(tester).pixels, 50);
      expect(
        _semanticsOf(tester, _previous).hasAction(SemanticsAction.tap),
        isTrue,
      );
    });
  });

  group('text scale', () {
    testWidgets('at 2.0 text, a taller child is not clipped', (tester) async {
      useViewSize(tester, _narrow);
      Widget at(double scale) => MediaQuery(
        data: MediaQueryData(
          size: _narrow,
          textScaler: TextScaler.linear(scale),
        ),
        child: _app(
          SingleChildScrollView(
            child: _shelf(
              children: [
                for (var i = 0; i < _coverCount; i++)
                  SizedBox(
                    key: _coverKey(i),
                    width: _coverWidth,
                    child: Text('A title that goes over some lines $i'),
                  ),
              ],
            ),
          ),
        ),
      );

      await _show(tester, at(1));
      final height = tester.getSize(find.byKey(_coverKey(0))).height;

      await tester.pumpWidget(at(2));
      await tester.pumpAndSettle();

      final grown = tester.getSize(find.byKey(_coverKey(0))).height;
      expect(grown, greaterThan(height));
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.byType(BgeShelf),
                matching: find.byType(SingleChildScrollView),
              ),
            )
            .height,
        grown,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('at 2.0 text, a long heading wraps above the buttons', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      const headingKey = Key('heading');
      await _show(
        tester,
        MediaQuery(
          data: const MediaQueryData(
            size: _narrow,
            textScaler: TextScaler.linear(2),
          ),
          child: _app(
            BgeShelf(
              heading: 'A heading far too long for one line of a narrow window',
              headingKey: headingKey,
              previousLabel: 'Previous',
              nextLabel: 'Next',
              actions: [TextButton(onPressed: () {}, child: const Text('All'))],
              children: _covers(),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(headingKey), findsOneWidget);
      expect(
        tester.getBottomLeft(find.byKey(headingKey)).dy,
        lessThanOrEqualTo(tester.getTopLeft(_next).dy),
      );
    });
  });

  group('placeholder', () {
    testWidgets('placeholder replaces the row, and the same header element '
        'stays', (tester) async {
      useViewSize(tester, _narrow);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      const headingKey = Key('heading');
      Widget shelf({Widget? placeholder}) => _app(
        _shelf(
          headingKey: headingKey,
          placeholder: placeholder,
          actions: [
            TextButton(
              key: _actionKey,
              focusNode: focus,
              onPressed: () {},
              child: const Text('Action'),
            ),
          ],
        ),
      );

      await _show(tester, shelf());
      final heading = tester.element(find.byKey(headingKey));
      final action = tester.element(find.byKey(_actionKey));
      focus.requestFocus();
      await tester.pump();

      await tester.pumpWidget(
        shelf(placeholder: const SizedBox(key: _placeholderKey)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(_placeholderKey), findsOneWidget);
      expect(find.byKey(_coverKey(0)), findsNothing);
      expect(tester.element(find.byKey(headingKey)), same(heading));
      expect(tester.element(find.byKey(_actionKey)), same(action));
      expect(focus.hasPrimaryFocus, isTrue);

      // And as the row and its buttons come back in front of the action.
      await tester.pumpWidget(shelf());
      await tester.pumpAndSettle();

      expect(_next, findsOneWidget);
      expect(
        tester.getCenter(_next).dx,
        lessThan(tester.getCenter(find.byKey(_actionKey)).dx),
      );
      expect(tester.element(find.byKey(_actionKey)), same(action));
      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets('a placeholder takes the buttons, and they come back from '
        'fresh metrics', (tester) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf()));
      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(
        _semanticsOf(tester, _previous).flagsCollection.isEnabled,
        Tristate.isTrue,
      );

      await tester.pumpWidget(_app(_shelf(placeholder: const SizedBox())));

      // Gone in that frame, not a frame later.
      expect(_previous, findsNothing);
      expect(_next, findsNothing);

      await tester.pumpAndSettle();
      expect(_next, findsNothing);

      // A row that fits has no buttons, whatever the last one needed.
      await tester.pumpWidget(
        _app(_shelf(children: _covers().take(2).toList())),
      );
      await tester.pumpAndSettle();
      expect(_next, findsNothing);

      await tester.pumpWidget(_app(_shelf(placeholder: const SizedBox())));
      await tester.pumpAndSettle();

      // A row that overflows has them, reading from its own start.
      await tester.pumpWidget(_app(_shelf()));
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, 0);
      expect(_next, findsOneWidget);
      expect(
        _semanticsOf(tester, _previous).flagsCollection.isEnabled,
        Tristate.isFalse,
      );
      expect(
        _semanticsOf(tester, _next).flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a change of resetToken under a placeholder throws nothing', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(
        tester,
        _app(_shelf(placeholder: const SizedBox(), resetToken: 1)),
      );

      await tester.pumpWidget(
        _app(_shelf(placeholder: const SizedBox(), resetToken: 2)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('a change of resetToken on a row not yet laid out throws '
        'nothing', (tester) async {
      // A route on top still builds what is under it, and doesn't lay it out,
      // so an answer landing then mounts a row that has no metrics yet.
      useViewSize(tester, _narrow);
      final shelf = ValueNotifier<Widget>(
        _shelf(placeholder: const SizedBox(), resetToken: 1),
      );
      addTearDown(shelf.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await _show(
        tester,
        MaterialApp(
          navigatorKey: navigator,
          theme: BgeTheme.light(),
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: shelf,
              builder: (context, value, _) => value,
            ),
          ),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        ),
      );
      await tester.pumpAndSettle();

      shelf.value = _shelf(resetToken: 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(_rowOf(tester).pixels, 0);
      expect(_next, findsOneWidget);
    });

    testWidgets('going before its measurement lands throws nothing', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await tester.pumpWidget(_app(_shelf()));
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('note', () {
    const headingKey = Key('heading');
    const noteKey = Key('note');
    const note = Text('A note about the row', key: noteKey);

    testWidgets('a note sits between the header and the row', (tester) async {
      useViewSize(tester, _narrow);
      await _show(tester, _app(_shelf(headingKey: headingKey, note: note)));

      final noteRect = tester.getRect(find.byKey(noteKey));
      expect(
        noteRect.top,
        greaterThan(tester.getBottomLeft(find.byKey(headingKey)).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(_coverKey(0))).dy - noteRect.bottom,
        BgeTokens.spaceSmValue,
      );
    });

    testWidgets('a note sits above a placeholder too', (tester) async {
      useViewSize(tester, _narrow);
      await _show(
        tester,
        _app(
          _shelf(
            headingKey: headingKey,
            note: note,
            placeholder: const SizedBox(key: _placeholderKey, height: 20),
          ),
        ),
      );

      final noteRect = tester.getRect(find.byKey(noteKey));
      expect(
        noteRect.top,
        greaterThan(tester.getBottomLeft(find.byKey(headingKey)).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(_placeholderKey)).dy - noteRect.bottom,
        BgeTokens.spaceSmValue,
      );
    });

    testWidgets('a note coming and going leaves the row where it was', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      final cover = FocusNode();
      addTearDown(cover.dispose);
      Widget shelf({Widget? note}) => _app(
        _shelf(
          note: note,
          children: _covers(focusNodes: {2: cover}),
        ),
      );

      await _show(tester, shelf());
      _rowOf(tester).jumpTo(100);
      cover.requestFocus();
      await tester.pumpAndSettle();

      await tester.pumpWidget(shelf(note: note));
      await tester.pumpAndSettle();
      expect(find.byKey(noteKey), findsOneWidget);
      expect(_rowOf(tester).pixels, 100);
      expect(cover.hasPrimaryFocus, isTrue);

      await tester.pumpWidget(shelf());
      await tester.pumpAndSettle();
      expect(find.byKey(noteKey), findsNothing);
      expect(_rowOf(tester).pixels, 100);
      expect(cover.hasPrimaryFocus, isTrue);
    });
    testWidgets("a note of the placeholder's type leaves the placeholder its "
        'state', (tester) async {
      final mounts = <String, int>{};
      // Unkeyed and of one type, so only their places tell them apart.
      Widget counted(String name) =>
          _CountsMounts(onMount: () => mounts[name] = (mounts[name] ?? 0) + 1);
      Widget shelf({required bool withNote}) => _app(
        _shelf(
          placeholder: counted('placeholder'),
          note: withNote ? counted('note') : null,
        ),
      );

      await _show(tester, shelf(withNote: false));
      await _show(tester, shelf(withNote: true));
      await _show(tester, shelf(withNote: false));

      expect(mounts, {'placeholder': 1, 'note': 1});
    });
  });

  group('equal heights', () {
    List<double> heightsOf(WidgetTester tester, int count) => [
      for (var i = 0; i < count; i++)
        tester.getSize(find.byKey(_coverKey(i))).height,
    ];

    testWidgets('off by default, children keep their own heights', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      await _show(
        tester,
        _app(
          _shelf(
            children: [
              for (final (i, height) in [40.0, 80.0, 60.0].indexed)
                SizedBox(key: _coverKey(i), width: 100, height: height),
            ],
          ),
        ),
      );

      expect(heightsOf(tester, 3), [40, 80, 60]);
    });

    testWidgets('equalHeights stretches every child to the tallest', (
      tester,
    ) async {
      useViewSize(tester, _narrow);
      Widget shelf({required bool equalHeights}) => _app(
        _shelf(
          equalHeights: equalHeights,
          children: [
            for (final (i, lines) in [1, 3, 2].indexed)
              SizedBox(
                key: _coverKey(i),
                width: 100,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (var l = 0; l < lines; l++) Text('line $l')],
                ),
              ),
          ],
        ),
      );

      await _show(tester, shelf(equalHeights: false));
      final natural = heightsOf(tester, 3);
      expect(natural[1], greaterThan(natural[2]));
      expect(natural[2], greaterThan(natural[0]));

      await tester.pumpWidget(shelf(equalHeights: true));
      await tester.pumpAndSettle();

      expect(heightsOf(tester, 3), everyElement(natural[1]));
    });

    testWidgets(
      'equalHeights measures a wrapping child at its own width, at 2.0 text',
      (tester) async {
        useViewSize(tester, _narrow);
        Widget shelf({required bool equalHeights}) => MediaQuery(
          data: const MediaQueryData(
            size: _narrow,
            textScaler: TextScaler.linear(2),
          ),
          // In a page that scrolls: the title runs to more lines than the
          // window is tall.
          child: _app(
            SingleChildScrollView(
              child: _shelf(
                equalHeights: equalHeights,
                children: [
                  SizedBox(
                    key: _coverKey(0),
                    width: 120,
                    child: const Text(
                      'A title long enough to wrap over a good many lines here',
                    ),
                  ),
                  SizedBox(
                    key: _coverKey(1),
                    width: 120,
                    child: const Text('Short'),
                  ),
                ],
              ),
            ),
          ),
        );

        await _show(tester, shelf(equalHeights: false));
        final [wrapped, oneLine] = heightsOf(tester, 2);
        expect(wrapped, greaterThan(oneLine));

        await tester.pumpWidget(shelf(equalHeights: true));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(heightsOf(tester, 2), [wrapped, wrapped]);
      },
    );
  });

  group('heading', () {
    testWidgets('the heading is a header', (tester) async {
      useViewSize(tester, _narrow);
      const headingKey = Key('heading');
      await _show(tester, _app(_shelf(headingKey: headingKey)));

      expect(
        tester.getSemantics(find.byKey(headingKey)),
        isSemantics(label: 'Heading', isHeader: true),
      );
    });
  });
}

/// Counts its mounts, to tell whether it kept its element.
class _CountsMounts extends StatefulWidget {
  const _CountsMounts({required this.onMount});

  final VoidCallback onMount;

  @override
  State<_CountsMounts> createState() => _CountsMountsState();
}

class _CountsMountsState extends State<_CountsMounts> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 20);
}
