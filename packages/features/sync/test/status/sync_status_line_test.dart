import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_queue/l10n/sync_localizations.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/streaming_queue.dart';

/// The navigation drawer's line saying where the session's changes stand
/// (#47).
void main() {
  late int reviews;

  setUp(() => reviews = 0);

  /// The line under a scope holding [waiting] and [stuck], null for a count
  /// not read, or under none when [scoped] is false, on the drawer's surface
  /// as the app shows it.
  Widget harness({
    ThemeData? theme,
    bool scoped = true,
    int? waiting = 0,
    int? stuck = 0,
    double? width,
  }) {
    Widget line = SyncStatusLine(onReview: () => reviews++);
    if (width != null) line = SizedBox(width: width, child: line);
    if (scoped) {
      line = BgeSyncStatusScope(waiting: waiting, stuck: stuck, child: line);
    }
    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: SyncLocalizations.localizationsDelegates,
      supportedLocales: SyncLocalizations.supportedLocales,
      home: Scaffold(
        body: width == null
            ? Drawer(child: ListView(children: [line]))
            : Align(alignment: AlignmentDirectional.topStart, child: line),
      ),
    );
  }

  BgeStatusColors colors(WidgetTester tester) =>
      BgeStatusColors.of(tester.element(find.byType(SyncStatusLine)));

  Icon iconOf(WidgetTester tester, Key line) => tester.widget<Icon>(
    find.descendant(of: find.byKey(line), matching: find.byType(Icon)),
  );

  Finder byKey(Key key) => find.byKey(key);

  // The words are in the drawer's text colour, not the status colour, which
  // falls under 7:1 as text on the drawer in high contrast (#47). The icon
  // keeps the status colour.
  void expectNeutralWords(WidgetTester tester, String words) => expect(
    tester.widget<Text>(find.text(words)).style?.color,
    Theme.of(
      tester.element(find.byType(SyncStatusLine)),
    ).colorScheme.onSurfaceVariant,
  );

  testWidgets('no scope, or nothing read, no line', (tester) async {
    for (final app in [
      harness(scoped: false),
      harness(waiting: null, stuck: null),
      // Each count read as nothing outstanding, and the other unread: not
      // All changes synced, which needs both.
      harness(stuck: null),
      harness(waiting: null),
    ]) {
      await tester.pumpWidget(app);

      expect(byKey(SyncStatusLine.syncedKey), findsNothing);
      expect(byKey(SyncStatusLine.waitingKey), findsNothing);
      expect(byKey(SyncStatusLine.stuckKey), findsNothing);
      expect(byKey(SyncStatusLine.reviewKey), findsNothing);
      // Built, and no height: a list counts a child that tall as offstage.
      final line = find.byType(SyncStatusLine, skipOffstage: false);
      expect(tester.getSize(line).height, 0);
    }
  });

  testWidgets('under a host, says nothing until the queue has been read', (
    tester,
  ) async {
    final queue = StreamingQueue();
    addTearDown(() => unawaited(queue.dispose()));
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: SyncLocalizations.localizationsDelegates,
        supportedLocales: SyncLocalizations.supportedLocales,
        home: Scaffold(
          body: Drawer(
            child: ListView(
              children: [
                SyncStatusScopeHost(
                  queue: queue,
                  child: SyncStatusLine(onReview: () => reviews++),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Zeros nobody has read are not "All changes synced".
    expect(byKey(SyncStatusLine.syncedKey), findsNothing);

    queue.pending.add(0);
    await tester.pumpAndSettle();
    expect(byKey(SyncStatusLine.syncedKey), findsNothing);

    queue.stuck.add(const []);
    await tester.pumpAndSettle();
    expect(find.text('All changes synced'), findsOneWidget);

    // A failed read takes the claim back until the queue reads again.
    queue.stuck.addError(StateError('read failed'));
    await tester.pumpAndSettle();
    expect(byKey(SyncStatusLine.syncedKey), findsNothing);
    expect(byKey(SyncStatusLine.waitingKey), findsNothing);
    expect(byKey(SyncStatusLine.stuckKey), findsNothing);
  });

  testWidgets('each count shows once read, whatever the other is doing', (
    tester,
  ) async {
    // Stuck read, the pending count not: the stuck line and its Review,
    // and no waiting or All synced line.
    await tester.pumpWidget(harness(waiting: null, stuck: 2));
    expect(find.text("2 changes couldn't sync"), findsOneWidget);
    expect(byKey(SyncStatusLine.reviewKey), findsOneWidget);
    expect(byKey(SyncStatusLine.waitingKey), findsNothing);
    expect(byKey(SyncStatusLine.syncedKey), findsNothing);

    // The other way round.
    await tester.pumpWidget(harness(waiting: 3, stuck: null));
    expect(find.text('3 changes waiting'), findsOneWidget);
    expect(byKey(SyncStatusLine.stuckKey), findsNothing);
    expect(byKey(SyncStatusLine.syncedKey), findsNothing);
  });

  testWidgets('nothing outstanding reads All changes synced', (tester) async {
    await tester.pumpWidget(harness());

    expect(
      find.descendant(
        of: byKey(SyncStatusLine.syncedKey),
        matching: find.text('All changes synced'),
      ),
      findsOneWidget,
    );
    final icon = iconOf(tester, SyncStatusLine.syncedKey);
    expect(icon.icon, BgeStatusColors.iconFor(BgeStatus.synced));
    expect(icon.color, colors(tester).synced);
    expectNeutralWords(tester, 'All changes synced');
    expect(byKey(SyncStatusLine.waitingKey), findsNothing);
    expect(byKey(SyncStatusLine.stuckKey), findsNothing);
    expect(byKey(SyncStatusLine.reviewKey), findsNothing);
  });

  testWidgets('waiting reads its plural', (tester) async {
    await tester.pumpWidget(harness(waiting: 1));
    expect(
      find.descendant(
        of: byKey(SyncStatusLine.waitingKey),
        matching: find.text('1 change waiting'),
      ),
      findsOneWidget,
    );
    final icon = iconOf(tester, SyncStatusLine.waitingKey);
    expect(icon.icon, BgeStatusColors.iconFor(BgeStatus.pending));
    expect(icon.color, colors(tester).pending);
    expectNeutralWords(tester, '1 change waiting');

    await tester.pumpWidget(harness(waiting: 3));
    expect(find.text('3 changes waiting'), findsOneWidget);
    expect(byKey(SyncStatusLine.syncedKey), findsNothing);
    expect(byKey(SyncStatusLine.stuckKey), findsNothing);
    expect(byKey(SyncStatusLine.reviewKey), findsNothing);
  });

  testWidgets('stuck reads its plural and Review calls back', (tester) async {
    await tester.pumpWidget(harness(stuck: 1));
    expect(
      find.descendant(
        of: byKey(SyncStatusLine.stuckKey),
        matching: find.text("1 change couldn't sync"),
      ),
      findsOneWidget,
    );
    final icon = iconOf(tester, SyncStatusLine.stuckKey);
    expect(icon.icon, BgeStatusColors.iconFor(BgeStatus.conflict));
    expect(icon.color, colors(tester).conflict);
    expectNeutralWords(tester, "1 change couldn't sync");

    await tester.pumpWidget(harness(stuck: 2));
    expect(find.text("2 changes couldn't sync"), findsOneWidget);
    expect(byKey(SyncStatusLine.syncedKey), findsNothing);
    expect(byKey(SyncStatusLine.waitingKey), findsNothing);

    final review = byKey(SyncStatusLine.reviewKey);
    expect(
      find.descendant(of: review, matching: find.text('Review')),
      findsOneWidget,
    );
    expect(tester.widget(review), isA<TextButton>());
    await tester.tap(review);
    expect(reviews, 1);
  });

  testWidgets('both show, stuck first', (tester) async {
    await tester.pumpWidget(harness(waiting: 2, stuck: 1));

    expect(byKey(SyncStatusLine.syncedKey), findsNothing);
    expect(
      tester.getRect(byKey(SyncStatusLine.stuckKey)).bottom,
      lessThanOrEqualTo(tester.getRect(byKey(SyncStatusLine.waitingKey)).top),
    );
  });

  testWidgets('each line is one node, and none is a live region', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(waiting: 2, stuck: 1));

    // The drawer is read on demand; a count that changes while it is open
    // is not news to announce.
    final stuck = tester.getSemantics(find.text("1 change couldn't sync"));
    expect(
      stuck,
      isSemantics(
        label: "1 change couldn't sync",
        isLiveRegion: false,
        isButton: false,
      ),
    );
    expect(
      tester.getSemantics(find.text('2 changes waiting')),
      isSemantics(label: '2 changes waiting', isLiveRegion: false),
    );

    // Review keeps a node of its own, named by its text: merged into the
    // line, it would stop being a control a screen reader can reach.
    final review = tester.getSemantics(byKey(SyncStatusLine.reviewKey));
    expect(
      review,
      isSemantics(label: 'Review', isButton: true, hasTapAction: true),
    );
    expect(review.id, isNot(stuck.id));

    await tester.pumpWidget(harness());
    expect(
      tester.getSemantics(find.text('All changes synced')),
      isSemantics(label: 'All changes synced', isLiveRegion: false),
    );
    handle.dispose();
  });

  testWidgets('at 2.0 text in 280 dp nothing overflows', (tester) async {
    useViewSize(tester, const Size(320, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(harness(waiting: 12, stuck: 12, width: 280));

    expect(tester.takeException(), isNull);
    final line = tester.getRect(find.byType(SyncStatusLine));
    for (final part in [
      find.text("12 changes couldn't sync"),
      find.text('12 changes waiting'),
      byKey(SyncStatusLine.reviewKey),
    ]) {
      final rect = tester.getRect(part);
      expect(rect.left, greaterThanOrEqualTo(line.left));
      expect(rect.right, lessThanOrEqualTo(line.right));
    }
    // The button's label fits inside it, uncut.
    final review = tester.getRect(byKey(SyncStatusLine.reviewKey));
    final label = tester.getRect(
      find.descendant(
        of: byKey(SyncStatusLine.reviewKey),
        matching: find.text('Review'),
      ),
    );
    expect(review.left, lessThanOrEqualTo(label.left));
    expect(review.right, greaterThanOrEqualTo(label.right));
  });

  testWidgets('Review sits after the words, and under them when they fill '
      'the line', (tester) async {
    useViewSize(tester, const Size(800, 600));
    Rect words() => tester.getRect(find.text("1 change couldn't sync"));
    Rect review() => tester.getRect(byKey(SyncStatusLine.reviewKey));

    await tester.pumpWidget(harness(stuck: 1, width: 600));
    expect(review().left, greaterThanOrEqualTo(words().right));
    expect(review().center.dy, moreOrLessEquals(words().center.dy));

    // At 2.0 the words take the whole width. Beside them, the button would
    // squeeze them into a column a few letters wide.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(harness(stuck: 1, width: 280));
    expect(review().top, greaterThanOrEqualTo(words().bottom));
  });

  group('accessibility audit', () {
    auditScreen(
      'SyncStatusLine, all synced',
      build: (theme) => harness(theme: theme),
    );
    auditScreen(
      'SyncStatusLine, waiting',
      build: (theme) => harness(theme: theme, waiting: 3),
    );
    auditScreen(
      'SyncStatusLine, stuck and waiting',
      build: (theme) => harness(theme: theme, waiting: 3, stuck: 2),
    );
  });
}
