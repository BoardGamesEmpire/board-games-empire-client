import 'dart:ui' show Tristate;

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const Key _fieldKey = ValueKey('field');
const Key _clearKey = ValueKey('clear');

Widget _field({
  ValueChanged<String>? onChanged,
  String initial = '',
  String label = 'Search your collection',
}) => Scaffold(
  body: BgeSearchField(
    label: label,
    clearLabel: 'Clear search',
    onChanged: onChanged ?? (_) {},
    initial: initial,
    fieldKey: _fieldKey,
    clearKey: _clearKey,
  ),
);

/// The `EditableText` inside the field: where primary focus lands when the
/// field has it.
FocusNode _fieldFocus(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_fieldKey)).focusNode!;

/// Gives the clear button primary focus, as a click or a Tab would.
void _focusClearButton(WidgetTester tester) => Focus.of(
  tester.element(
    find.descendant(
      of: find.byKey(_clearKey),
      matching: find.byIcon(Icons.clear),
    ),
  ),
).requestFocus();

void main() {
  group('BgeSearchField', () {
    testWidgets('typing reports each edit with the new text', (tester) async {
      final seen = <String>[];
      await tester.pumpWidget(hostAtSize(tester, _field(onChanged: seen.add)));

      await tester.enterText(find.byKey(_fieldKey), 'c');
      await tester.enterText(find.byKey(_fieldKey), 'ca');
      await tester.enterText(find.byKey(_fieldKey), 'cat');

      expect(seen, ['c', 'ca', 'cat']);
    });

    testWidgets('is a search field with a search icon', (tester) async {
      await tester.pumpWidget(hostAtSize(tester, _field()));

      expect(
        tester.widget<TextField>(find.byKey(_fieldKey)).textInputAction,
        TextInputAction.search,
      );
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('shows a visible label, not a hint', (tester) async {
      await tester.pumpWidget(hostAtSize(tester, _field()));
      expect(find.text('Search your collection'), findsOneWidget);

      await tester.enterText(find.byKey(_fieldKey), 'cat');
      await tester.pump();
      expect(
        find.text('Search your collection'),
        findsOneWidget,
        reason: 'a label stays once the user types; a hint would not',
      );
    });

    testWidgets('initial seeds the text once and is not a controlled value', (
      tester,
    ) async {
      await tester.pumpWidget(hostAtSize(tester, _field(initial: 'cat')));
      expect(find.text('cat'), findsOneWidget);
      expect(find.byKey(_clearKey), findsOneWidget);

      await tester.enterText(find.byKey(_fieldKey), 'dog');
      await tester.pumpWidget(hostAtSize(tester, _field(initial: 'bird')));
      await tester.pump();

      expect(
        find.text('dog'),
        findsOneWidget,
        reason: 'a rebuilt widget with another initial leaves typed text',
      );
    });

    group('the clear button', () {
      testWidgets('is absent while the field is empty', (tester) async {
        await tester.pumpWidget(hostAtSize(tester, _field()));

        expect(find.byKey(_clearKey), findsNothing);
      });

      testWidgets('appears with text and goes with it', (tester) async {
        await tester.pumpWidget(hostAtSize(tester, _field()));

        await tester.enterText(find.byKey(_fieldKey), 'cat');
        await tester.pump();
        expect(find.byKey(_clearKey), findsOneWidget);

        await tester.enterText(find.byKey(_fieldKey), '');
        await tester.pump();
        expect(find.byKey(_clearKey), findsNothing);
      });

      testWidgets('sends an empty string once and empties the field', (
        tester,
      ) async {
        final seen = <String>[];
        await tester.pumpWidget(
          hostAtSize(tester, _field(onChanged: seen.add)),
        );
        await tester.enterText(find.byKey(_fieldKey), 'cat');
        await tester.pump();
        seen.clear();

        await tester.tap(find.byKey(_clearKey));
        await tester.pump();

        expect(seen, ['']);
        expect(
          tester.widget<TextField>(find.byKey(_fieldKey)).controller!.text,
          '',
        );
        expect(find.byKey(_clearKey), findsNothing);
      });

      // In both, the field is seeded and never focused, and the button is
      // focused alone. Focus then has no earlier stop on the field to fall
      // back to when the button leaves the tree: only the handler's own
      // request puts it there.
      testWidgets('pressed with a pointer leaves focus on the field', (
        tester,
      ) async {
        final seen = <String>[];
        await tester.pumpWidget(
          hostAtSize(tester, _field(initial: 'cat', onChanged: seen.add)),
        );
        _focusClearButton(tester);
        await tester.pump();

        await tester.tap(find.byKey(_clearKey));
        await tester.pumpAndSettle();

        expect(seen, ['']);
        expect(find.byKey(_clearKey), findsNothing);
        expect(_fieldFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets('activated from the keyboard leaves focus on the field', (
        tester,
      ) async {
        final seen = <String>[];
        await tester.pumpWidget(
          hostAtSize(tester, _field(initial: 'cat', onChanged: seen.add)),
        );
        _focusClearButton(tester);
        await tester.pump();

        await activateByKeyboard(tester, find.byKey(_clearKey));

        expect(seen, ['']);
        expect(find.byKey(_clearKey), findsNothing);
        expect(_fieldFocus(tester).hasPrimaryFocus, isTrue);
      });
    });

    group('accessibility', () {
      testWidgets('the field is a text field named by its label', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(hostAtSize(tester, _field()));

        final named = find.bySemanticsLabel('Search your collection');
        expect(named, findsOneWidget, reason: 'one node carries the name');
        final data = tester.getSemantics(named).getSemanticsData();
        expect(data.flagsCollection.isTextField, isTrue);
        expect(data.label, 'Search your collection');
        handle.dispose();
      });

      testWidgets('the clear button is a named button', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(hostAtSize(tester, _field(initial: 'cat')));

        final data = tester
            .getSemantics(find.byKey(_clearKey))
            .getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        // An icon button's tooltip is its name: iOS and web join it to the
        // label, Android hands it to TalkBack as the tooltip text.
        expect(data.tooltip, 'Clear search');
        handle.dispose();
      });

      testWidgets('the clear button meets the tap target guidelines', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(hostAtSize(tester, _field(initial: 'cat')));

        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        final size = tester.getSize(find.byKey(_clearKey));
        expect(
          size.width,
          greaterThanOrEqualTo(BgeTokens.standard.minTapTarget),
        );
        expect(
          size.height,
          greaterThanOrEqualTo(BgeTokens.standard.minTapTarget),
        );
        handle.dispose();
      });
    });

    group('at 320dp wide and 200% text', () {
      const narrow = Size(320, 480);
      const longLabel =
          'Search the games your household owns by name, designer or '
          'publisher';

      // The label is drawn in two places, resting inside the field and
      // floating on its border, and it must be whole in both.
      for (final label in const ['Search your collection', longLabel]) {
        for (final (state, text, focused) in const [
          ('resting', '', false),
          ('floating, with text', 'a long search for something rare', false),
          ('floating, focused and empty', '', true),
        ]) {
          testWidgets('"${label.substring(0, 12)}\u{2026}" is whole, $state, '
              'and nothing overflows', (tester) async {
            await tester.pumpWidget(
              hostAtSize(
                tester,
                _field(label: label, initial: text),
                size: narrow,
                textScale: 2,
              ),
            );
            if (focused) _fieldFocus(tester).requestFocus();
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            final box = tester.getRect(find.byType(BgeSearchField));
            expect(box.left, greaterThanOrEqualTo(0));
            expect(box.right, lessThanOrEqualTo(narrow.width));

            final labelText = find.text(label);
            expect(labelText, findsOneWidget);
            final paragraph = tester.renderObject<RenderParagraph>(labelText);
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason: 'the label is on one line, not cut off',
            );
            final drawn = tester.getRect(labelText);
            final field = tester.getRect(find.byKey(_fieldKey));
            expect(drawn.width, greaterThan(0));
            expect(field.left, lessThanOrEqualTo(drawn.left + 0.5));
            expect(field.right, greaterThanOrEqualTo(drawn.right - 0.5));
            // Vertically it may stand above the field: a floating label is
            // centred on the top border, as in every outlined field.
            expect(field.top, lessThanOrEqualTo(drawn.center.dy));
            expect(field.bottom, greaterThanOrEqualTo(drawn.bottom - 0.5));

            if (text.isNotEmpty) {
              final clear = tester.getRect(find.byKey(_clearKey));
              expect(clear.right, lessThanOrEqualTo(narrow.width));
              expect(clear.width, greaterThanOrEqualTo(48));
              expect(clear.height, greaterThanOrEqualTo(48));
            }
          });
        }
      }
    });
  });
}
