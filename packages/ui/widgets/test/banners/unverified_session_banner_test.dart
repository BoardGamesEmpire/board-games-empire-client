import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ui/ui.dart';

/// #98: shell notice for a session restored without server confirmation.
void main() {
  const message = 'Offline — using your saved sign-in.';
  const dismiss = 'Dismiss';

  Widget host({required bool visible, VoidCallback? onDismiss}) => MaterialApp(
    home: Column(
      children: [
        UnverifiedSessionBanner(
          visible: visible,
          message: message,
          dismissLabel: dismiss,
          onDismiss: onDismiss ?? () {},
        ),
        const Expanded(child: SizedBox()),
      ],
    ),
  );

  testWidgets('renders nothing when not visible', (tester) async {
    await tester.pumpWidget(host(visible: false));

    expect(find.text(message), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('shows message and dismiss control when visible', (tester) async {
    await tester.pumpWidget(host(visible: true));
    await tester.pump();

    expect(find.text(message), findsOneWidget);
    expect(find.byTooltip(dismiss), findsOneWidget);
  });

  testWidgets('the message is a live region — appearance itself is the '
      'readout trigger (SemanticsService.announce is deprecated, and '
      'Android deprecated announcement events outright)', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(visible: true));
    await tester.pump();

    expect(
      tester.getSemantics(find.text(message)),
      matchesSemantics(label: message, isLiveRegion: true),
    );

    handle.dispose();
  });

  testWidgets('hidden leaves no live region in the tree — nothing for '
      'assistive tech to re-read', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(visible: false));
    await tester.pump();

    expect(find.text(message), findsNothing);
    expect(find.bySemanticsLabel(message), findsNothing);

    handle.dispose();
  });

  testWidgets('a new episode recreates the live-region node — appear, '
      'disappear, reappear', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(visible: true));
    await tester.pump();
    expect(find.bySemanticsLabel(message), findsOneWidget);

    await tester.pumpWidget(host(visible: false));
    await tester.pump();
    expect(find.bySemanticsLabel(message), findsNothing);

    await tester.pumpWidget(host(visible: true));
    await tester.pump();
    expect(
      tester.getSemantics(find.text(message)),
      matchesSemantics(label: message, isLiveRegion: true),
    );

    handle.dispose();
  });

  testWidgets('the dismiss control reports through onDismiss — hiding is '
      'the HOST\'s decision, expressed back through visible (dismissal and '
      'layout inset compensation must share an owner)', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      host(visible: true, onDismiss: () => dismissed += 1),
    );
    await tester.pump();

    await tester.tap(find.byTooltip(dismiss));
    await tester.pump();

    expect(dismissed, 1);
    // The banner itself does NOT self-hide: with visible still true it is
    // still rendered, awaiting the host's verdict.
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('the dismiss control is reachable and labelled for '
      'assistive tech', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(visible: true));
    await tester.pump();

    expect(find.bySemanticsLabel(dismiss), findsOneWidget);

    handle.dispose();
  });

  testWidgets('does not steal focus on appearance', (tester) async {
    final focusNode = FocusNode(debugLabel: 'field');
    addTearDown(focusNode.dispose);

    // Scaffold: TextField needs a Material ancestor, which the bare
    // MaterialApp home does not provide (the banner brings its own
    // Material, but that does not cover siblings).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              UnverifiedSessionBanner(
                visible: false,
                message: message,
                dismissLabel: dismiss,
                onDismiss: () {},
              ),
              TextField(focusNode: focusNode, autofocus: true),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              UnverifiedSessionBanner(
                visible: true,
                message: message,
                dismissLabel: dismiss,
                onDismiss: () {},
              ),
              TextField(focusNode: focusNode),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      focusNode.hasFocus,
      isTrue,
      reason: 'the banner informs; it must not interrupt',
    );
  });
}
