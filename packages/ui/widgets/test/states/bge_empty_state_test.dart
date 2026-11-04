import 'dart:ui' show Tristate;

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(Widget state) => MaterialApp(
  theme: BgeTheme.light(),
  home: BgePage(centerVertically: true, child: state),
);

List<String> _labels(WidgetTester tester) {
  final labels = <String>[];
  void collect(SemanticsNode node) {
    final label = node.getSemanticsData().label;
    if (label.isNotEmpty) labels.add(label);
    node.visitChildren((child) {
      collect(child);
      return true;
    });
  }

  tester.binding.rootPipelineOwner.visitChildren((owner) {
    final root = owner.semanticsOwner?.rootSemanticsNode;
    if (root != null) collect(root);
  });
  return labels;
}

void main() {
  group('BgeEmptyState', () {
    testWidgets('empty: title and body are one live region', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeEmptyState(
            title: 'No events yet',
            body: 'Plan one to get started.',
          ),
        ),
      );

      final title = tester.getSemantics(find.text('No events yet'));
      expect(
        title,
        isSemantics(
          isLiveRegion: true,
          label: 'No events yet\nPlan one to get started.',
        ),
      );
      expect(
        tester.getSemantics(find.text('Plan one to get started.')),
        same(title),
        reason: 'one announcement, not a title followed by a fragment',
      );
      handle.dispose();
    });

    testWidgets('empty: the icon says nothing', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeEmptyState(
            icon: Icons.event_busy_outlined,
            title: 'No events yet',
            body: 'Plan one to get started.',
          ),
        ),
      );

      expect(find.byIcon(Icons.event_busy_outlined), findsOneWidget);
      expect(_labels(tester), ['No events yet\nPlan one to get started.']);
      handle.dispose();
    });

    testWidgets('empty: the action is its own node and not focused on '
        'appearance', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          BgeEmptyState(
            title: 'No events yet',
            body: 'Plan one to get started.',
            action: FilledButton(
              onPressed: () {},
              child: const Text('Plan an event'),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = tester.getSemantics(find.text('Plan an event'));
      expect(action, isSemantics(label: 'Plan an event', isButton: true));
      expect(action.flagsCollection.isFocused, Tristate.isFalse);
      expect(
        action.id,
        isNot(tester.getSemantics(find.text('No events yet')).id),
      );
      expect(
        tester.getRect(find.text('Plan an event')).top,
        greaterThan(
          tester.getRect(find.text('Plan one to get started.')).bottom,
        ),
      );
      handle.dispose();
    });

    testWidgets('empty without body', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const BgeEmptyState(title: 'No events')));

      expect(
        tester.getSemantics(find.text('No events')),
        isSemantics(isLiveRegion: true, label: 'No events'),
      );
      expect(_labels(tester), ['No events']);
      handle.dispose();
    });

    testWidgets('fits 320dp at 200% text', (tester) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          BgePage(
            centerVertically: true,
            child: BgeEmptyState(
              icon: Icons.event_busy_outlined,
              title: 'You have no upcoming events',
              body: 'Plan one, or ask a friend to invite you to theirs.',
              action: FilledButton(
                onPressed: () {},
                child: const Text('Plan an event'),
              ),
            ),
          ),
          size: const Size(320, 640),
          textScale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
