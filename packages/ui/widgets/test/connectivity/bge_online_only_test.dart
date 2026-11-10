import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _reason = "Available when you're online";

Widget _host(Widget child, {bool offline = true}) => MaterialApp(
  theme: BgeTheme.light(),
  home: Scaffold(
    body: BgeConnectivityScope(
      offline: offline,
      noticeShowing: offline,
      onlineOnlyReason: _reason,
      child: Center(child: child),
    ),
  ),
);

/// How many semantics nodes carry [text] in their label or hint.
int _nodesMentioning(WidgetTester tester, String text) {
  var count = 0;
  void visit(SemanticsNode node) {
    if (node.label.contains(text) || node.hint.contains(text)) count++;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(
    tester
        .renderObject(find.byType(Scaffold))
        .owner!
        .semanticsOwner!
        .rootSemanticsNode!,
  );
  return count;
}

void main() {
  group('BgeOnlineOnly', () {
    testWidgets('online the control reads as its own, with nothing drawn', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          BgeOnlineOnly(
            child: FilledButton(onPressed: () {}, child: const Text('Delete')),
          ),
          offline: false,
        ),
      );

      expect(find.text(_reason), findsNothing);
      expect(
        tester.getSemantics(find.byType(FilledButton)),
        matchesSemantics(
          label: 'Delete',
          isButton: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('the control keeps its state and its node when the '
        'connection comes and goes', (tester) async {
      final handle = tester.ensureSemantics();
      Widget at({required bool offline}) => _host(
        BgeOnlineOnly(
          child: FilledButton(
            onPressed: offline ? null : () {},
            child: const Text('Delete'),
          ),
        ),
        offline: offline,
      );
      await tester.pumpWidget(at(offline: false));
      final state = tester.state(find.byType(FilledButton));
      final node = tester.getSemantics(find.byType(FilledButton)).id;

      await tester.pumpWidget(at(offline: true));
      expect(tester.state(find.byType(FilledButton)), same(state));
      expect(tester.getSemantics(find.byType(FilledButton)).id, node);

      await tester.pumpWidget(at(offline: false));
      expect(tester.state(find.byType(FilledButton)), same(state));
      expect(tester.getSemantics(find.byType(FilledButton)).id, node);
      handle.dispose();
    });

    testWidgets("offline merges the reason into the control's node", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeOnlineOnly(
            child: FilledButton(onPressed: null, child: Text('Delete')),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.text('Delete')),
        matchesSemantics(
          label: 'Delete',
          hint: _reason,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    // Flutter's text-contrast guideline skips a node only when its own flags
    // say disabled, and would otherwise measure the dimmed label (#50).
    testWidgets("offline the merged node's own flags say disabled", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeOnlineOnly(
            child: FilledButton(onPressed: null, child: Text('Delete')),
          ),
        ),
      );

      final node = tester.getSemantics(find.text('Delete'));
      expect(node.hint, _reason);
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });

    testWidgets("offline merges the reason into a chip's node", (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeOnlineOnly(
            child: ChoiceChip(
              label: Text('Yes'),
              selected: true,
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.text('Yes')),
        matchesSemantics(
          label: 'Yes',
          hint: _reason,
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('offline shows the note once, unannounced', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeOnlineOnly(
            child: FilledButton(onPressed: null, child: Text('Delete')),
          ),
        ),
      );

      expect(find.text(_reason), findsOneWidget);
      expect(
        _nodesMentioning(tester, 'online'),
        1,
        reason: 'only the control carries the reason; the note is silent',
      );
      handle.dispose();
    });

    testWidgets('showNote: false leaves the reason to the hint', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const BgeOnlineOnly(
            showNote: false,
            child: FilledButton(onPressed: null, child: Text('Delete')),
          ),
        ),
      );

      expect(find.text(_reason), findsNothing);
    });

    testWidgets('the note is bodySmall in onSurfaceVariant', (tester) async {
      await tester.pumpWidget(
        _host(
          const BgeOnlineOnly(
            child: FilledButton(onPressed: null, child: Text('Delete')),
          ),
        ),
      );

      final style = tester.widget<Text>(find.text(_reason)).style!;
      final theme = BgeTheme.light();
      expect(style.color, theme.colorScheme.onSurfaceVariant);
      expect(style.fontSize, theme.textTheme.bodySmall!.fontSize);
    });
  });

  group('BgeOnlineOnlyNote', () {
    testWidgets('draws nothing while online', (tester) async {
      await tester.pumpWidget(_host(const BgeOnlineOnlyNote(), offline: false));

      expect(find.text(_reason), findsNothing);
    });

    testWidgets('offline, the reason is visible and no node carries it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const BgeOnlineOnlyNote()));

      expect(find.text(_reason), findsOneWidget);
      expect(_nodesMentioning(tester, 'online'), 0);
      handle.dispose();
    });
  });

  group('BgeOnlineOnlyLabel', () {
    testWidgets('offline: two lines, one label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const MenuItemButton(
            child: BgeOnlineOnlyLabel('Delete'),
          ),
        ),
      );

      expect(find.text('Delete'), findsOneWidget);
      expect(find.text(_reason), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Delete')),
        matchesSemantics(label: 'Delete\n$_reason', hasEnabledState: true),
      );
      expect(
        tester.getSemantics(find.text(_reason)).id,
        tester.getSemantics(find.text('Delete')).id,
      );
      handle.dispose();
    });

    testWidgets('online: the label alone', (tester) async {
      await tester.pumpWidget(
        _host(
          MenuItemButton(
            onPressed: () {},
            child: const BgeOnlineOnlyLabel('Delete'),
          ),
          offline: false,
        ),
      );

      expect(find.text('Delete'), findsOneWidget);
      expect(find.text(_reason), findsNothing);
    });

    for (final offline in [true, false]) {
      testWidgets('speaks semanticsLabel for the label, '
          '${offline ? 'offline' : 'online'}', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _host(
            MenuItemButton(
              onPressed: offline ? null : () {},
              child: const BgeOnlineOnlyLabel(
                'Seafarers',
                semanticsLabel: 'Seafarers, expansion for Catan',
              ),
            ),
            offline: offline,
          ),
        );

        final label = tester
            .getSemantics(
              find.bySemanticsLabel(RegExp('^Seafarers, expansion for Catan')),
            )
            .getSemanticsData()
            .label;
        expect(label.contains(_reason), offline);
        handle.dispose();
      });
    }
  });
}
