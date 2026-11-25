import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

void main() {
  late MockApiKeyRemoteDataSource remote;
  late List<String> opened;

  // Local noon: the screen shows dates in local time, and `toLocal()` keeps
  // a local time's date in every zone a test machine is in. Noon UTC was the
  // next day from UTC+12 on.
  final expires = DateTime(2027, 2, 1, 12);
  final used = DateTime(2026, 11, 20, 12);

  setUp(() {
    remote = MockApiKeyRemoteDataSource();
    opened = [];
    answerGrantable(remote);
  });

  Widget screen({
    ThemeData? theme,
    Future<void> Function(String id)? openKey,
    Future<void> Function()? createKey,
  }) => hostScreen(
    ApiKeyListScreen(
      remote: remote,
      openKey:
          openKey ??
          (id) async {
            opened.add(id);
          },
      createKey: createKey,
    ),
    theme: theme,
  );

  Future<void> show(WidgetTester tester, {ThemeData? theme}) async {
    await tester.pumpWidget(screen(theme: theme));
    await tester.pumpAndSettle();
  }

  /// The words a screen reader reads for the row of the key [id].
  String rowLabel(WidgetTester tester, String id) => tester
      .getSemantics(
        find.descendant(
          of: find.byKey(ApiKeyListScreen.rowKey(id)),
          matching: find.byType(ListTile),
        ),
      )
      .label;

  testWidgets(
    'rows say name, start, scope count, expiry, status in words and last used',
    (tester) async {
      answerPage(remote, [
        apiKey(
          'k_1',
          scopes: const [
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'events:write'),
            ApiKeyScope(slug: 'households:read'),
          ],
          expiresAt: expires,
          lastUsedAt: used,
        ),
        apiKey('k_2', name: 'Backup', start: 'bge_zz', enabled: false),
      ]);
      // Grantable failed, so the rows give counts only.
      when(
        remote.fetchGrantable,
      ).thenThrow(const ApiKeyTransientException('down'));

      await show(tester);

      for (final words in [
        'CI deploy',
        'bge_a1B2…',
        '3 permissions',
        'Expires Feb 1, 2027',
        'Enabled',
        'Last used Nov 20, 2026',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(ApiKeyListScreen.rowKey('k_1')),
            matching: find.text(words),
          ),
          findsOneWidget,
          reason: words,
        );
      }
      expect(
        rowLabel(tester, 'k_1'),
        allOf(
          contains('CI deploy'),
          contains('bge_a1B2…'),
          contains('3 permissions'),
          contains('Expires Feb 1, 2027'),
          contains('Enabled'),
          contains('Last used Nov 20, 2026'),
        ),
      );
      expect(
        rowLabel(tester, 'k_2'),
        allOf(
          contains('Backup'),
          contains('1 permission\n'),
          contains('Never expires'),
          contains('Disabled'),
        ),
      );
    },
  );

  testWidgets('rows name the highest risk level in words when grantable '
      'loads', (tester) async {
    answerGrantable(remote, [
      permission('collection:read'),
      permission('events:write', riskLevel: RiskLevel.high),
      permission('users:manage', riskLevel: RiskLevel.critical),
      permission('odd:thing', riskLevel: RiskLevel.unknown),
    ]);
    answerPage(remote, [
      apiKey(
        'k_1',
        scopes: const [
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'events:write'),
          // Unknown sorts after Critical in the enum, and still isn't the
          // highest; a slug no longer grantable doesn't count at all.
          ApiKeyScope(slug: 'odd:thing'),
          ApiKeyScope(slug: 'gone:away'),
        ],
      ),
      apiKey(
        'k_2',
        scopes: const [ApiKeyScope(slug: 'users:manage')],
      ),
    ]);

    await show(tester);

    expect(find.text('4 permissions, highest risk High'), findsOneWidget);
    expect(find.text('1 permission, highest risk Critical'), findsOneWidget);
    expect(
      rowLabel(tester, 'k_1'),
      contains('4 permissions, highest risk High'),
    );
  });

  testWidgets('a key with no scopes says it works nowhere', (tester) async {
    answerPage(remote, [apiKey('k_1', scopes: const [])]);

    await show(tester);

    expect(
      find.text('No permissions: this key works nowhere'),
      findsOneWidget,
    );
  });

  testWidgets('a null lastUsedAt reads Never used', (tester) async {
    answerPage(remote, [apiKey('k_1')]);

    await show(tester);

    expect(find.text('Never used'), findsOneWidget);
    expect(rowLabel(tester, 'k_1'), contains('Never used'));
  });

  testWidgets('a key the server has no name for reads Unnamed key', (
    tester,
  ) async {
    answerPage(remote, [apiKey('k_1', name: null, start: null)]);

    await show(tester);

    expect(find.text('Unnamed key'), findsOneWidget);
    expect(find.textContaining('…'), findsNothing);
  });

  testWidgets('every row is outlined and ringed', (tester) async {
    answerPage(remote, [apiKey('k_1'), apiKey('k_2')]);

    await show(tester);

    expect(find.byType(BgeOutlinedRow), findsNWidgets(2));
    expect(find.byType(BgeRowFocusRing), findsNWidgets(2));
    expect(
      await keyboardFocusShowsRing(tester, find.text('CI deploy').first),
      isTrue,
    );
  });

  testWidgets('semanticChildCount follows the visible rows', (tester) async {
    answerPage(remote, [
      apiKey('k_1'),
      apiKey('k_2', enabled: false),
      apiKey('k_3'),
    ]);
    final semantics = tester.ensureSemantics();

    await show(tester);
    expect(scrollChildCountOnScrollingNode(tester), 3);

    await tester.tap(
      find.descendant(
        of: find.byKey(ApiKeyListScreen.filterKey),
        matching: find.text('Disabled'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsNothing);
    expect(find.byKey(ApiKeyListScreen.rowKey('k_2')), findsOneWidget);
    // One row no longer scrolls, so there is no scrolling node to read:
    // the scroll view's own count is what a screen reader would be given.
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      1,
    );
    semantics.dispose();
  });

  testWidgets('tapping a row calls openKey with its id, then re-reads page 1', (
    tester,
  ) async {
    answerPage(remote, [apiKey('k_1'), apiKey('k_2')]);
    final page = Completer<void>();
    await tester.pumpWidget(
      screen(
        openKey: (id) {
          opened.add(id);
          return page.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    verify(() => remote.fetchPage(limit: any(named: 'limit'))).called(1);

    await tester.tap(find.text('CI deploy').last);
    await tester.pump();
    expect(opened, ['k_2']);
    // Nothing is read again while the key's page is open.
    verifyNever(() => remote.fetchPage(limit: any(named: 'limit')));

    // The key was disabled on its own page.
    answerPage(remote, [apiKey('k_1'), apiKey('k_2', enabled: false)]);
    page.complete();
    await tester.pumpAndSettle();

    verify(() => remote.fetchPage(limit: any(named: 'limit'))).called(1);
    expect(rowLabel(tester, 'k_2'), contains('Disabled'));
  });

  testWidgets('a key opened from page 2 keeps its row and focus on return', (
    tester,
  ) async {
    answerPage(remote, [apiKey('k_1')], hasMore: true);
    answerPage(remote, [apiKey('k_2', name: 'Backup')], page: 2);
    late NavigatorState navigator;
    await tester.pumpWidget(
      screen(
        // As the app opens a key: its page is pushed over the list, and the
        // open completes when that page is popped.
        openKey: (id) {
          opened.add(id);
          return navigator.push(
            MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    navigator = tester.state(find.byType(Navigator));
    await tester.ensureVisible(find.byKey(ApiKeyListScreen.moreKey));
    await tester.tap(find.byKey(ApiKeyListScreen.moreKey));
    await tester.pumpAndSettle();

    final row = Focus.of(tester.element(find.text('Backup')))..requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, ['k_2']);
    expect(row.hasFocus, isFalse);

    // The key was disabled on its own page.
    answerPage(remote, [
      apiKey('k_2', name: 'Backup', enabled: false),
    ], page: 2);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    verify(
      () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
    ).called(2);
    expect(rowLabel(tester, 'k_2'), contains('Disabled'));
    expect(row.hasPrimaryFocus, isTrue);
  });

  testWidgets('a second tap while a key is open opens nothing more', (
    tester,
  ) async {
    answerPage(remote, [apiKey('k_1')]);
    final page = Completer<void>();
    await tester.pumpWidget(
      screen(
        openKey: (id) {
          opened.add(id);
          return page.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('CI deploy'));
    await tester.pump();
    await tester.tap(find.text('CI deploy'));
    await tester.pump();

    expect(opened, ['k_1']);
    page.complete();
    await tester.pumpAndSettle();
  });

  group('coming back', () {
    /// Counts the reads of page 1 since the last count.
    void expectPageReads(int count) => count == 0
        ? verifyNever(() => remote.fetchPage(limit: any(named: 'limit')))
        : verify(
            () => remote.fetchPage(limit: any(named: 'limit')),
          ).called(count);

    /// A page pushed over the list, as the app pushes a key's own page, with
    /// a way to close it.
    Route<void> pageOver() => MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ),
    );

    testWidgets('a page taken away without a pop, whose open never '
        'completes, still re-reads the list and lets it open again', (
      tester,
    ) async {
      answerPage(remote, [apiKey('k_1')]);
      late NavigatorState navigator;
      final routes = <Route<void>>[];
      await tester.pumpWidget(
        screen(
          // As a router's push answers when Back in the browser takes the
          // page away: with a future that never completes.
          openKey: (id) {
            opened.add(id);
            routes.add(pageOver());
            navigator.push(routes.last);
            return Completer<void>().future;
          },
        ),
      );
      await tester.pumpAndSettle();
      navigator = tester.state(find.byType(Navigator));
      expectPageReads(1);

      await tester.tap(find.text('CI deploy'));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);
      expectPageReads(0);

      answerPage(remote, [apiKey('k_1', enabled: false)]);
      navigator.removeRoute(routes.single);
      await tester.pumpAndSettle();

      expect(find.text('Close'), findsNothing);
      expectPageReads(1);
      expect(rowLabel(tester, 'k_1'), contains('Disabled'));

      // Not left waiting on the open that never completed.
      await tester.tap(find.text('CI deploy'));
      await tester.pumpAndSettle();
      expect(opened, ['k_1', 'k_1']);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('a page taken away before it had fully arrived frees the '
        'list too', (tester) async {
      answerPage(remote, [apiKey('k_1')]);
      late NavigatorState navigator;
      final routes = <Route<void>>[];
      await tester.pumpWidget(
        screen(
          openKey: (id) {
            routes.add(pageOver());
            navigator.push(routes.last);
            return Completer<void>().future;
          },
        ),
      );
      await tester.pumpAndSettle();
      navigator = tester.state(find.byType(Navigator));
      expectPageReads(1);

      await tester.tap(find.text('CI deploy'));
      // Part-way through its entrance: it has not yet covered the list.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      navigator.removeRoute(routes.single);
      await tester.pumpAndSettle();

      expectPageReads(1);
      await tester.tap(find.text('CI deploy'));
      await tester.pumpAndSettle();
      expect(routes, hasLength(2));
    });

    testWidgets('a page the list never opened, gone from over it, reads '
        'the list again', (tester) async {
      answerPage(remote, [apiKey('k_1')]);
      await show(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expectPageReads(1);

      // As when a link or a reload builds the list beneath a key's page:
      // nothing here opened it.
      navigator.push(pageOver());
      await tester.pumpAndSettle();
      expectPageReads(0);

      answerPage(remote, [apiKey('k_new', name: 'Backup'), apiKey('k_1')]);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expectPageReads(1);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('one page gone is one read, though both its signs come', (
      tester,
    ) async {
      answerPage(remote, [apiKey('k_1')]);
      late NavigatorState navigator;
      await tester.pumpWidget(
        screen(openKey: (id) => navigator.push(pageOver())),
      );
      await tester.pumpAndSettle();
      navigator = tester.state(find.byType(Navigator));
      expectPageReads(1);

      await tester.tap(find.text('CI deploy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // The push's future completed and the list's route is the top one
      // again: one return.
      expectPageReads(1);
    });
  });

  group('Create key', () {
    Finder createFab() => find.byKey(ApiKeyListScreen.createFabKey);

    FocusNode createFocus(WidgetTester tester) =>
        tester.widget<BgeExtendedFab>(createFab()).focusNode!;

    /// Counts the reads of page 1 since the last count.
    void expectPageReads(int count) => count == 0
        ? verifyNever(() => remote.fetchPage(limit: any(named: 'limit')))
        : verify(
            () => remote.fetchPage(limit: any(named: 'limit')),
          ).called(count);

    /// A page pushed over the list, as the app pushes the one that makes a
    /// key, with a way to close it.
    Route<void> pageOver() => MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ),
    );

    testWidgets('with no createKey there is no Create key', (tester) async {
      answerPage(remote, const []);
      await show(tester);

      expect(find.byKey(ApiKeyListScreen.emptyKey), findsOneWidget);
      expect(find.text('Create key'), findsNothing);
      expect(find.byType(BgeExtendedFab), findsNothing);
    });

    testWidgets('Create key opens createKey and the list re-reads after', (
      tester,
    ) async {
      answerPage(remote, [apiKey('k_1')]);
      final page = Completer<void>();
      var asked = 0;
      await tester.pumpWidget(
        screen(
          createKey: () {
            asked++;
            return page.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      expectPageReads(1);
      expect(find.text('Create key'), findsOneWidget);

      await tester.tap(createFab());
      await tester.pump();
      expect(asked, 1);
      // Nothing is read again while the page is open.
      expectPageReads(0);

      // A key was made on it.
      answerPage(remote, [apiKey('k_new', name: 'Backup'), apiKey('k_1')]);
      page.complete();
      await tester.pumpAndSettle();

      expectPageReads(1);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('a list with no keys offers it under its words too, and '
        'that opens the same page', (tester) async {
      answerPage(remote, const []);
      final page = Completer<void>();
      var asked = 0;
      await tester.pumpWidget(
        screen(
          createKey: () {
            asked++;
            return page.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      final under = find.byKey(ApiKeyListScreen.emptyCreateKey);
      expect(
        find.descendant(
          of: find.byKey(ApiKeyListScreen.emptyKey),
          matching: under,
        ),
        findsOneWidget,
      );
      expect(find.text('Create key'), findsNWidgets(2));

      await tester.tap(under);
      await tester.pump();
      expect(asked, 1);
      // The floating one has focus, to take it back when the page closes:
      // the one under the words goes once there is a key to show.
      expect(createFocus(tester).hasPrimaryFocus, isTrue);

      answerPage(remote, [apiKey('k_new')]);
      page.complete();
      await tester.pumpAndSettle();

      expect(under, findsNothing);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);
      expect(createFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('320dp at 2.0 lays out both without one covering the '
        'other', (tester) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      answerPage(remote, const []);
      await tester.pumpWidget(screen(createKey: () async {}));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final under = tester.getRect(
        find.byKey(ApiKeyListScreen.emptyCreateKey),
      );
      final floating = tester.getRect(createFab());
      expect(
        under.overlaps(floating),
        isFalse,
        reason: '$under is under the floating button at $floating',
      );
      expect(floating.right, lessThanOrEqualTo(320));
      expect(under.right, lessThanOrEqualTo(320));
    });

    testWidgets('a filter that shows none offers it only as the floating '
        'button', (tester) async {
      answerPage(remote, [apiKey('k_1')]);
      await tester.pumpWidget(screen(createKey: () async {}));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byKey(ApiKeyListScreen.filterKey),
          matching: find.text('Disabled'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No disabled keys'), findsOneWidget);
      expect(find.byKey(ApiKeyListScreen.emptyCreateKey), findsNothing);
      expect(createFab(), findsOneWidget);
    });

    testWidgets('a second press while its page is open opens nothing more, '
        'and neither does a row', (tester) async {
      answerPage(remote, [apiKey('k_1')]);
      final page = Completer<void>();
      var asked = 0;
      await tester.pumpWidget(
        screen(
          createKey: () {
            asked++;
            return page.future;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(createFab());
      await tester.pump();
      await tester.tap(createFab());
      await tester.pump();
      await tester.tap(find.text('CI deploy'));
      await tester.pump();

      expect(asked, 1);
      expect(opened, isEmpty);
      page.complete();
      await tester.pumpAndSettle();
    });

    testWidgets("a screen reader's Create key has focus back when the page "
        'it opened closes', (tester) async {
      answerPage(remote, [apiKey('k_1')]);
      final semantics = tester.ensureSemantics();
      late NavigatorState navigator;
      await tester.pumpWidget(
        screen(createKey: () => navigator.push(pageOver())),
      );
      await tester.pumpAndSettle();
      navigator = tester.state(find.byType(Navigator));
      expect(createFocus(tester).hasPrimaryFocus, isFalse);

      // A double tap with a screen reader moves no input focus of its own.
      tester.semantics.tap(find.semantics.byLabel('Create key'));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(createFocus(tester).hasPrimaryFocus, isTrue);
      semantics.dispose();
    });

    testWidgets('a page taken away without a pop, whose open never '
        'completes, still re-reads the list and lets it open again', (
      tester,
    ) async {
      answerPage(remote, [apiKey('k_1')]);
      late NavigatorState navigator;
      final routes = <Route<void>>[];
      var asked = 0;
      await tester.pumpWidget(
        screen(
          // As a router's push answers when Back in the browser takes the
          // page away: with a future that never completes.
          createKey: () {
            asked++;
            routes.add(pageOver());
            navigator.push(routes.last);
            return Completer<void>().future;
          },
        ),
      );
      await tester.pumpAndSettle();
      navigator = tester.state(find.byType(Navigator));
      expectPageReads(1);

      await tester.tap(createFab());
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);
      expectPageReads(0);

      answerPage(remote, [apiKey('k_new'), apiKey('k_1')]);
      navigator.removeRoute(routes.single);
      await tester.pumpAndSettle();

      expect(find.text('Close'), findsNothing);
      expectPageReads(1);
      expect(find.byKey(ApiKeyListScreen.rowKey('k_new')), findsOneWidget);

      // Not left waiting on the open that never completed.
      await tester.tap(createFab());
      await tester.pumpAndSettle();
      expect(asked, 2);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('a page taken away before it had fully arrived frees the '
        'list too', (tester) async {
      answerPage(remote, [apiKey('k_1')]);
      late NavigatorState navigator;
      final routes = <Route<void>>[];
      await tester.pumpWidget(
        screen(
          createKey: () {
            routes.add(pageOver());
            navigator.push(routes.last);
            return Completer<void>().future;
          },
        ),
      );
      await tester.pumpAndSettle();
      navigator = tester.state(find.byType(Navigator));
      expectPageReads(1);

      await tester.tap(createFab());
      // Part-way through its entrance: it has not yet covered the list.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      navigator.removeRoute(routes.single);
      await tester.pumpAndSettle();

      expectPageReads(1);
      await tester.tap(createFab());
      await tester.pumpAndSettle();
      expect(routes, hasLength(2));
    });

    testWidgets('one page gone is one read, though both its signs come', (
      tester,
    ) async {
      answerPage(remote, [apiKey('k_1')]);
      late NavigatorState navigator;
      await tester.pumpWidget(
        screen(createKey: () => navigator.push(pageOver())),
      );
      await tester.pumpAndSettle();
      navigator = tester.state(find.byType(Navigator));
      expectPageReads(1);

      await tester.tap(createFab());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // The push's future completed and the list's route is the top one
      // again: one return.
      expectPageReads(1);
    });
  });

  testWidgets("the filter's empty result names the filter", (tester) async {
    answerPage(remote, [apiKey('k_1')]);

    await show(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(ApiKeyListScreen.filterKey),
        matching: find.text('Disabled'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ApiKeyListScreen.emptyKey), findsOneWidget);
    expect(find.text('No disabled keys'), findsOneWidget);
    expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsNothing);

    // Every key is disabled now: Enabled names itself.
    answerPage(remote, [apiKey('k_1', enabled: false)]);
    await tester.tap(find.byKey(ApiKeyListScreen.refreshKey));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(ApiKeyListScreen.filterKey),
        matching: find.text('Enabled'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No enabled keys'), findsOneWidget);
  });

  testWidgets('a filter with nothing loaded yet says more may be unloaded', (
    tester,
  ) async {
    answerPage(remote, [apiKey('k_1')], hasMore: true);

    await show(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(ApiKeyListScreen.filterKey),
        matching: find.text('Disabled'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No disabled keys'), findsOneWidget);
    expect(
      find.text(
        'Some may be among the keys not loaded yet. Choose More to load them.',
      ),
      findsOneWidget,
    );
    // More follows the words rather than sitting a page below them.
    final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      tester.getRect(find.byKey(ApiKeyListScreen.moreKey)).bottom,
      lessThanOrEqualTo(viewport.height),
    );
  });

  testWidgets('no keys at all says what a key is', (tester) async {
    answerPage(remote, const []);

    await show(tester);

    expect(find.byKey(ApiKeyListScreen.emptyKey), findsOneWidget);
    expect(find.text('No API keys yet'), findsOneWidget);
    expect(find.textContaining('An API key lets'), findsOneWidget);
  });

  testWidgets('a load failure shows BgeErrorState and retry reloads', (
    tester,
  ) async {
    when(
      () => remote.fetchPage(limit: any(named: 'limit')),
    ).thenThrow(const ApiKeyTransientException('down'));

    await show(tester);

    expect(
      tester.widget(find.byKey(ApiKeyListScreen.failedKey)),
      isA<BgeErrorState>(),
    );
    expect(find.text("Couldn't load your API keys"), findsOneWidget);
    // Nothing that answered: the connection is what to check.
    expect(
      find.text('Check your connection, then try again.'),
      findsOneWidget,
    );

    answerPage(remote, [apiKey('k_1')]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.byKey(ApiKeyListScreen.failedKey), findsNothing);
    expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsOneWidget);
  });

  testWidgets("a load the server refused says why in the server's words", (
    tester,
  ) async {
    when(() => remote.fetchPage(limit: any(named: 'limit'))).thenThrow(
      const ApiKeyPermanentException(
        'refused',
        statusCode: 400,
        apiMessage: 'Listing keys is switched off on this server',
      ),
    );

    await show(tester);

    expect(find.text("Couldn't load your API keys"), findsOneWidget);
    expect(
      find.text('Listing keys is switched off on this server'),
      findsOneWidget,
    );
    expect(find.text('Check your connection, then try again.'), findsNothing);
  });

  testWidgets("Try again waits on the page's title as the read starts", (
    tester,
  ) async {
    final retried = Completer<PaginatedResult<ApiKey>>();
    var reads = 0;
    when(() => remote.fetchPage(limit: any(named: 'limit'))).thenAnswer(
      (_) => reads++ == 0
          ? Future.error(const ApiKeyTransientException('down'))
          : retried.future,
    );
    await show(tester);
    expect(find.byKey(ApiKeyListScreen.failedKey), findsOneWidget);

    // The retry is autofocused; a keyboard press goes as the read starts.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(find.byKey(ApiKeyListScreen.failedKey), findsNothing);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNot(isA<FocusScopeNode>()));
    expect(
      find.descendant(
        of: find.byWidget(focused!.context!.widget),
        matching: find.text('API keys'),
      ),
      findsOneWidget,
    );

    retried.complete(pageOf([apiKey('k_1')]));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, same(focused));
  });

  testWidgets('a failed re-read keeps the rows and their focus, and says so '
      'in text', (tester) async {
    answerPage(remote, [apiKey('k_1'), apiKey('k_2', name: 'Backup')]);
    final page = Completer<void>();
    await tester.pumpWidget(
      screen(
        openKey: (id) {
          opened.add(id);
          return page.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    // Opened from the keyboard, as focus comes back to the row after.
    final row = Focus.of(tester.element(find.text('Backup')))..requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, ['k_2']);

    when(
      () => remote.fetchPage(limit: any(named: 'limit')),
    ).thenThrow(const ApiKeyTransientException('down'));
    page.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsOneWidget);
    expect(find.byKey(ApiKeyListScreen.rowKey('k_2')), findsOneWidget);
    expect(find.byKey(ApiKeyListScreen.failedKey), findsNothing);
    expect(row.hasPrimaryFocus, isTrue);
    expect(
      find.descendant(
        of: find.byKey(ApiKeyListScreen.refreshFailedKey),
        matching: find.text(
          "Couldn't refresh your API keys. They may be out of date.",
        ),
      ),
      findsOneWidget,
    );

    // Its retry reads again, and a read that works takes the banner away.
    answerPage(remote, [apiKey('k_1')]);
    await tester.tap(find.byKey(ApiKeyListScreen.refreshRetryKey));
    await tester.pumpAndSettle();
    expect(find.byKey(ApiKeyListScreen.refreshFailedKey), findsNothing);
    expect(find.byKey(ApiKeyListScreen.rowKey('k_2')), findsNothing);
  });

  testWidgets('More loads the next page under the rows', (tester) async {
    answerPage(remote, [apiKey('k_1')], hasMore: true);
    answerPage(remote, [apiKey('k_2', name: 'Backup')], page: 2);

    await show(tester);
    await tester.ensureVisible(find.byKey(ApiKeyListScreen.moreKey));
    await tester.tap(find.byKey(ApiKeyListScreen.moreKey));
    await tester.pumpAndSettle();

    // Page 2 joins page 1, under it, rather than taking its place.
    final first = find.byKey(ApiKeyListScreen.rowKey('k_1'));
    final second = find.byKey(ApiKeyListScreen.rowKey('k_2'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
    expect(find.byKey(ApiKeyListScreen.moreKey), findsNothing);
  });

  testWidgets('a failed More says so and keeps the rows and the button', (
    tester,
  ) async {
    answerPage(remote, [apiKey('k_1')], hasMore: true);
    when(
      () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
    ).thenThrow(const ApiKeyTransientException('down'));

    await show(tester);
    await tester.ensureVisible(find.byKey(ApiKeyListScreen.moreKey));
    await tester.tap(find.byKey(ApiKeyListScreen.moreKey));
    await tester.pumpAndSettle();

    expect(find.byKey(ApiKeyListScreen.moreFailedKey), findsOneWidget);
    expect(
      find.text("Couldn't load more keys. Choose More to try again."),
      findsOneWidget,
    );
    expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsOneWidget);
    expect(find.byKey(ApiKeyListScreen.moreKey), findsOneWidget);
  });

  testWidgets('More keeps focus while it loads', (tester) async {
    answerPage(remote, [apiKey('k_1')], hasMore: true);
    final more = Completer<PaginatedResult<ApiKey>>();
    when(
      () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
    ).thenAnswer((_) => more.future);
    final semantics = tester.ensureSemantics();

    await show(tester);
    await tester.ensureVisible(find.byKey(ApiKeyListScreen.moreKey));
    final node = Focus.of(tester.element(find.text('More')))..requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.text('Loading more keys…'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading more keys…'), findsOneWidget);
    expect(node.hasPrimaryFocus, isTrue);

    more.complete(pageOf([apiKey('k_2')], page: 2));
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('Refresh re-reads page 1', (tester) async {
    answerPage(remote, [apiKey('k_1')]);

    await show(tester);
    verify(() => remote.fetchPage(limit: any(named: 'limit'))).called(1);

    answerPage(remote, [apiKey('k_1'), apiKey('k_2', name: 'Backup')]);
    await tester.tap(find.byKey(ApiKeyListScreen.refreshKey));
    await tester.pumpAndSettle();

    verify(() => remote.fetchPage(limit: any(named: 'limit'))).called(1);
    expect(find.byKey(ApiKeyListScreen.rowKey('k_2')), findsOneWidget);
  });

  testWidgets('320dp at 2.0 lays out every row without overflow', (
    tester,
  ) async {
    useViewSize(tester, const Size(320, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    answerPage(remote, [
      apiKey(
        'k_1',
        name: 'A rather long name of 32 chars!!',
        scopes: const [
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'events:write'),
        ],
        expiresAt: expires,
        lastUsedAt: used,
      ),
    ], hasMore: true);
    answerGrantable(remote, [
      permission('collection:read', riskLevel: RiskLevel.critical),
    ]);

    await show(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('2 permissions, highest risk Critical'), findsOneWidget);
  });

  group('accessibility audit', () {
    // Names the screen for tool/check_a11y_audit.dart: ApiKeyListScreen.
    Widget Function(ThemeData) screenWith(void Function() seed) => (theme) {
      seed();
      return screen(theme: theme);
    };

    void rows() {
      answerGrantable(remote, [
        permission('collection:read'),
        permission('users:manage', riskLevel: RiskLevel.critical),
      ]);
      answerPage(remote, [
        apiKey(
          'k_1',
          scopes: const [
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'users:manage'),
          ],
          expiresAt: expires,
          lastUsedAt: used,
        ),
        apiKey('k_2', name: null, enabled: false, scopes: const []),
        apiKey('k_3', name: 'Backup', start: null),
      ], hasMore: true);
    }

    auditScreen(
      'loaded',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyListScreen.rowKey('k_1')), findsOneWidget);
      },
    );

    auditScreen(
      'loaded, scrolled to More',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await scrollListToEnd(
          tester,
          find.byKey(ApiKeyListScreen.moreKey),
          mustScroll: false,
        );
      },
    );

    auditScreen(
      'More failed',
      build: screenWith(() {
        rows();
        when(
          () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
        ).thenThrow(const ApiKeyTransientException('down'));
      }),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await scrollListToEnd(
          tester,
          find.byKey(ApiKeyListScreen.moreKey),
          mustScroll: false,
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(ApiKeyListScreen.moreKey),
            matching: find.byType(OutlinedButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyListScreen.moreFailedKey), findsOneWidget);
      },
    );

    auditScreen(
      'refresh failed',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        when(
          () => remote.fetchPage(limit: any(named: 'limit')),
        ).thenThrow(const ApiKeyTransientException('down'));
        await tester.tap(find.byKey(ApiKeyListScreen.refreshKey));
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyListScreen.refreshFailedKey), findsOneWidget);
      },
    );

    auditScreen(
      'empty',
      build: screenWith(() => answerPage(remote, const [])),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyListScreen.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'loaded, with Create key',
      build: (theme) {
        rows();
        return screen(theme: theme, createKey: () async {});
      },
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyListScreen.createFabKey), findsOneWidget);
      },
    );

    auditScreen(
      'empty, with Create key under its words and floating',
      build: (theme) {
        answerPage(remote, const []);
        return screen(theme: theme, createKey: () async {});
      },
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyListScreen.emptyCreateKey), findsOneWidget);
        expect(find.byKey(ApiKeyListScreen.createFabKey), findsOneWidget);
      },
    );

    auditScreen(
      'filtered to nothing',
      build: screenWith(() => answerPage(remote, [apiKey('k_1')])),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byKey(ApiKeyListScreen.filterKey),
            matching: find.text('Disabled'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('No disabled keys'), findsOneWidget);
      },
    );

    auditScreen(
      'failed',
      build: screenWith(
        () => when(
          () => remote.fetchPage(limit: any(named: 'limit')),
        ).thenThrow(const ApiKeyTransientException('down')),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyListScreen.failedKey), findsOneWidget);
      },
    );

    auditScreen(
      'loading',
      build: screenWith(
        () => when(
          () => remote.fetchPage(limit: any(named: 'limit')),
        ).thenAnswer((_) => Completer<PaginatedResult<ApiKey>>().future),
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(ApiKeyListScreen.loadingKey), findsOneWidget);
      },
    );
  });
}
