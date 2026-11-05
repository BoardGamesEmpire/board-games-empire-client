import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/widgets/folded_description.dart';
import 'package:game_catalog/src/widgets/game_description.dart';

import '../support/catalog_app.dart';

/// The quick look's description, folded to four lines (#707).
void main() {
  late List<Uri> opened;

  setUp(() => opened = []);

  /// Many lines of one paragraph at any width these tests use.
  final long = List.filled(120, 'word').join(' ');

  /// Hosts [markdown] in a scroll view, as the quick look does, in a window
  /// 360dp wide. [host] wraps the description inside the scroll view. Unless
  /// [settle] is false, returns once it has been measured.
  Future<void> show(
    WidgetTester tester,
    String markdown, {
    Widget Function(Widget description)? host,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final description = FoldedDescription(
      markdown: markdown,
      onOpenLink: opened.add,
    );
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: SingleChildScrollView(
            child: host == null ? description : host(description),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  /// One line of the description's paragraphs, at a 1.0 text scale.
  double lineAtOneX(WidgetTester tester) {
    final body = Theme.of(tester.element(find.byType(FoldedDescription)))
        .textTheme
        .bodyMedium!;
    return body.fontSize! * body.height!;
  }

  Finder clip() => find.descendant(
    of: find.byType(FoldedDescription),
    matching: find.byType(ClipRect),
  );

  Finder toggle() => find.byKey(FoldedDescription.toggleKey);

  testWidgets('a short description shows whole, with no More', (tester) async {
    await show(tester, 'A short one.');

    expect(find.textContaining('A short one.'), findsOneWidget);
    expect(toggle(), findsNothing);
  });

  testWidgets('a long one is clipped to four lines with More', (tester) async {
    final handle = tester.ensureSemantics();
    await show(tester, long);

    expect(
      tester.getSize(clip()).height,
      moreOrLessEquals(4 * lineAtOneX(tester), epsilon: 1),
    );
    expect(find.text('More'), findsOneWidget);
    expect(
      tester.getSemantics(toggle()),
      isSemantics(
        label: 'More',
        isButton: true,
        hasTapAction: true,
        hasExpandedState: true,
        isExpanded: false,
      ),
    );

    handle.dispose();
  });

  testWidgets('More expands it in place, and Less folds it', (tester) async {
    final handle = tester.ensureSemantics();
    await show(tester, long);

    await tester.tap(toggle());
    await tester.pump();

    // The clip stays, cutting nothing.
    expect(
      tester.getSize(clip()).height,
      tester.getSize(find.byType(GameDescription)).height,
    );
    expect(
      tester.getSize(find.byType(FoldedDescription)).height,
      greaterThan(8 * lineAtOneX(tester)),
    );
    expect(
      tester.getSemantics(toggle()),
      isSemantics(
        label: 'Less',
        isButton: true,
        hasExpandedState: true,
        isExpanded: true,
      ),
    );

    await tester.tap(toggle());
    await tester.pump();

    expect(
      tester.getSize(clip()).height,
      moreOrLessEquals(4 * lineAtOneX(tester), epsilon: 1),
    );
    expect(
      tester.getSemantics(toggle()),
      isSemantics(label: 'More', hasExpandedState: true, isExpanded: false),
    );

    handle.dispose();
  });

  testWidgets('measuring it does not build the description again', (
    tester,
  ) async {
    // Built again, a screen reader's place in it would be lost, as when an
    // image arriving late takes it past the fold.
    await show(tester, long, settle: false);
    final first = tester.element(find.byType(GameDescription));

    await tester.pumpAndSettle();

    expect(toggle(), findsOneWidget);
    expect(tester.element(find.byType(GameDescription)), same(first));
  });

  testWidgets('More and Less do not build the description again', (
    tester,
  ) async {
    // Built again, its images would load again and flash, and a screen
    // reader's place in it would be lost.
    await show(tester, long);
    final first = tester.element(find.byType(GameDescription));

    await tester.tap(toggle());
    await tester.pump();
    expect(tester.element(find.byType(GameDescription)), same(first));

    await tester.tap(toggle());
    await tester.pump();
    expect(tester.element(find.byType(GameDescription)), same(first));
  });

  testWidgets('the toggle keeps focus through More and Less', (tester) async {
    await show(tester, long);
    final focus = Focus.of(tester.element(find.text('More')));
    focus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.text('Less'), findsOneWidget);
    expect(focus.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.text('More'), findsOneWidget);
    expect(focus.hasPrimaryFocus, isTrue);
  });

  /// Five one-line paragraphs. Four lines' fold ends inside the gap after
  /// the third.
  final fiveParagraphs = [
    'Paragraph one',
    'Paragraph two',
    'Paragraph three',
    'Paragraph four',
    'Paragraph five',
  ].join('\n\n');

  /// Expects a screen reader to hear the first three of [fiveParagraphs]
  /// while folded, and all five once More is pressed.
  Future<void> expectOnlyDrawnParagraphsHeard(WidgetTester tester) async {
    expect(toggle(), findsOneWidget);
    for (final drawn in ['one', 'two', 'three']) {
      expect(find.semantics.byLabel(RegExp('Paragraph $drawn')), findsOne);
    }
    for (final cut in ['four', 'five']) {
      expect(find.semantics.byLabel(RegExp('Paragraph $cut')), findsNothing);
    }

    await tester.tap(toggle());
    await tester.pump();

    for (final paragraph in ['one', 'two', 'three', 'four', 'five']) {
      expect(find.semantics.byLabel(RegExp('Paragraph $paragraph')), findsOne);
    }
  }

  testWidgets(
    'folded, a screen reader hears only the paragraphs drawn above the cut',
    (tester) async {
      // Regression test of the probe behind #707's choice to clip the
      // rendered Markdown: under a ClipRect, a paragraph wholly below the cut
      // leaves the semantics tree.
      final handle = tester.ensureSemantics();
      await show(tester, fiveParagraphs);

      await expectOnlyDrawnParagraphsHeard(tester);

      handle.dispose();
    },
  );

  testWidgets("a host that merges its children's semantics doesn't undo the "
      'cut', (tester) async {
    // Merged into one node, every paragraph would be in its label, drawn or
    // not.
    final handle = tester.ensureSemantics();
    await show(
      tester,
      fiveParagraphs,
      host: (description) => Semantics(container: true, child: description),
    );

    await expectOnlyDrawnParagraphsHeard(tester);

    handle.dispose();
  });

  testWidgets('at 2.0 text the fold is twice as tall', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await show(tester, long);

    expect(
      tester.getSize(clip()).height,
      moreOrLessEquals(2 * 4 * lineAtOneX(tester), epsilon: 1),
    );
    expect(toggle(), findsOneWidget);
  });

  testWidgets('a link in the folded part still opens', (tester) async {
    await show(tester, 'See [the rules](https://example.com/rules).\n\n$long');
    expect(toggle(), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('the rules'));
    await tester.pump();

    expect(opened, [Uri.parse('https://example.com/rules')]);
  });
}
