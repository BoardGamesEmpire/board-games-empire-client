import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/notifications.dart';
import 'package:ui/ui.dart';

import '../support/fake_notification_remote.dart';
import '../support/harness.dart';

void main() {
  late FakeNotificationRemote remote;
  late List<NotificationTarget> opened;

  setUp(() {
    remote = FakeNotificationRemote();
    opened = [];
  });

  const offline = NotificationTransientException('offline');
  const refused = NotificationPermanentException('no', statusCode: 400);

  /// A notification that opens its household: "Bo joined Home <id>".
  UserNotification joined(
    String id, {
    bool read = false,
    DateTime? createdAt,
  }) => UserNotification(
    id: id,
    type: 'HouseholdInviteAccepted',
    payload: {
      'householdId': 'h-$id',
      'householdName': 'Home $id',
      'memberName': 'Bo',
    },
    read: read,
    readAt: read ? DateTime.utc(2026, 11, 26, 13) : null,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 26, 12),
  );

  /// A notification of a kind this version can't word: a plain row.
  UserNotification unknown(String id, {bool read = false}) => UserNotification(
    id: id,
    type: 'SomethingNew',
    payload: const {},
    read: read,
    readAt: read ? DateTime.utc(2026, 11, 26, 13) : null,
    createdAt: DateTime.utc(2026, 11, 25, 12),
  );

  String titleOf(String id) => 'Bo joined Home $id';
  const plainTitle = "A notification this version of the app can't show";

  NotificationPage page(
    List<UserNotification> items, {
    String? nextCursor,
  }) => NotificationPage(items: items, nextCursor: nextCursor);

  Widget screen({
    ThemeData? theme,
    bool offline = false,
    NotificationCountCubit? count,
  }) {
    final page = NotificationsScreen(
      remote: remote,
      onOpen: (context, target) async => opened.add(target),
    );
    return hostScreen(
      count == null ? page : BlocProvider.value(value: count, child: page),
      theme: theme,
      offline: offline,
    );
  }

  /// A count cubit on [remote], closed when the test ends.
  NotificationCountCubit countCubit() {
    final cubit = NotificationCountCubit(remote);
    addTearDown(cubit.close);
    return cubit;
  }

  Finder row(String id) => find.byKey(NotificationsScreen.rowKey(id));

  NotificationTile tileOf(WidgetTester tester, String id) =>
      tester.widget<NotificationTile>(
        find.descendant(of: row(id), matching: find.byType(NotificationTile)),
      );

  int? semanticChildCount(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byType(CustomScrollView))
      .semanticChildCount;

  /// Whether row [id]'s tile has keyboard focus.
  bool rowHasFocus(WidgetTester tester, String id) => tester
      .widget<ListTile>(
        find.descendant(of: row(id), matching: find.byType(ListTile)),
      )
      .focusNode!
      .hasPrimaryFocus;

  /// The focus node the button under [finder] was given.
  FocusNode buttonFocus(WidgetTester tester, Finder finder) => tester
      .widget<ButtonStyleButton>(
        find.descendant(
          of: finder,
          matching: find.bySubtype<ButtonStyleButton>(),
          matchRoot: true,
        ),
      )
      .focusNode!;

  String? primaryFocusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  Finder markAll() => find.byKey(NotificationsScreen.markAllKey);
  Finder loadMore() => find.byKey(NotificationsScreen.loadMoreKey);
  Finder refreshButton() => find.byKey(NotificationsScreen.refreshKey);

  Finder markAllFailed() => find.byKey(NotificationsScreen.markAllFailedKey);
  Finder loadMoreFailed() => find.byKey(NotificationsScreen.loadMoreFailedKey);
  Finder refreshFailed() => find.byKey(NotificationsScreen.refreshFailedKey);

  /// The Dismiss on the footer banner [banner].
  Finder dismissOn(Finder banner) =>
      find.descendant(of: banner, matching: find.text('Dismiss'));

  /// Expects [banner] in the page's footer, outside the list's scroll view,
  /// saying [message] as a live region, and no SnackBar.
  void expectFooterBanner(WidgetTester tester, Finder banner, String message) {
    expect(banner, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final widget = tester.widget<BgeInlineBanner>(banner);
    expect(widget.message, message);
    expect(widget.tone, BgeBannerTone.error);
    expect(widget.announce, isTrue);
    expect(
      find.descendant(of: find.byType(CustomScrollView), matching: banner),
      findsNothing,
    );
    expect(
      find.descendant(of: find.byType(BgePinnedFooter), matching: banner),
      findsOneWidget,
    );
    // The banner's merged node, reached from inside it.
    final node = tester.getSemantics(
      find.descendant(of: banner, matching: find.byType(Icon)).first,
    );
    expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
  }

  /// A touch pull down from the top of the list, held for the indicator to
  /// snap into place and call for the refresh.
  Future<void> pull(WidgetTester tester) async {
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 300),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('loading shows BgeLoadingState', (tester) async {
    final first = Completer<NotificationPage>();
    remote.scriptPages([first.future]);

    await tester.pumpWidget(screen());
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(BgeStateSliver),
        matching: find.byKey(NotificationsScreen.loadingKey),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<BgeLoadingState>(find.byType(BgeLoadingState)).label,
      'Loading your notifications\u{2026}',
    );
    expect(markAll(), findsNothing);
    expect(loadMore(), findsNothing);

    first.complete(page(const []));
    await tester.pumpAndSettle();
    expect(find.byType(BgeLoadingState), findsNothing);
  });

  testWidgets('empty shows BgeEmptyState "No notifications yet"', (
    tester,
  ) async {
    remote.scriptPages([page(const [])]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    final empty = find.descendant(
      of: find.byType(BgeStateSliver),
      matching: find.byKey(NotificationsScreen.emptyKey),
    );
    expect(empty, findsOneWidget);
    expect(
      tester.widget<BgeEmptyState>(empty).title,
      'No notifications yet',
    );
    expect(markAll(), findsNothing);
    expect(loadMore(), findsNothing);
  });

  testWidgets('rows render newest first, read and unread', (tester) async {
    remote.scriptPages([
      page([
        joined('new', createdAt: DateTime.utc(2026, 11, 27)),
        joined('old', read: true, createdAt: DateTime.utc(2026, 11, 20)),
        unknown('odd'),
      ]),
    ]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    // In the server's order, which is newest first.
    final tops = [
      for (final id in ['new', 'old', 'odd']) tester.getTopLeft(row(id)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(find.text(titleOf('new')), findsOneWidget);
    expect(find.text(titleOf('old')), findsOneWidget);
    expect(find.text(plainTitle), findsOneWidget);

    expect(tileOf(tester, 'new').read, isFalse);
    expect(tileOf(tester, 'old').read, isTrue);
    expect(tileOf(tester, 'odd').read, isFalse);

    // Each row is outlined, as a record on a list screen is.
    for (final id in ['new', 'old', 'odd']) {
      expect(
        find.descendant(of: row(id), matching: find.byType(BgeOutlinedRow)),
        findsOneWidget,
      );
    }
    // The quote is selectable on the page: the tile is not cut.
    expect(tileOf(tester, 'new').quoteMaxLines, isNull);

    // A screen reader counts the rows loaded. Three rows don't scroll, so
    // the scroll view's own count is what a screen reader is given.
    expect(semanticChildCount(tester), 3);
  });

  testWidgets('tapping a row with a target calls onOpen with it and marks '
      'it read', (tester) async {
    final count = countCubit();
    remote
      // Read as the page opens, and again once a is marked read.
      ..scriptUnreadCounts([4, 3])
      ..scriptPages([
        page([joined('a'), joined('b')]),
      ])
      ..scriptMarkRead([null]);

    await tester.pumpWidget(screen(count: count));
    await tester.pumpAndSettle();
    expect(count.state.unread, 4);

    await tester.tap(find.text(titleOf('a')));
    await tester.pumpAndSettle();

    expect(opened, [const HouseholdTarget('h-a')]);
    expect(remote.markReadCalls, [
      ['a'],
    ]);
    expect(tileOf(tester, 'a').read, isTrue);
    expect(tileOf(tester, 'b').read, isFalse);
    // The bell's count hears of it.
    expect(count.state.unread, 3);
  });

  testWidgets('while what a row opened is open, a second open does nothing', (
    tester,
  ) async {
    final pages = <Completer<void>>[];
    remote
      ..scriptPages([
        page([joined('a'), joined('b')]),
      ])
      ..scriptMarkRead([null, null]);

    await tester.pumpWidget(
      hostScreen(
        NotificationsScreen(
          remote: remote,
          onOpen: (context, target) {
            opened.add(target);
            final page = Completer<void>();
            pages.add(page);
            return page.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(titleOf('a')));
    await tester.tap(find.text(titleOf('a')));
    await tester.tap(find.text(titleOf('b')));
    await tester.pumpAndSettle();

    // One open: the first row's, which is read. The others did nothing.
    expect(opened, [const HouseholdTarget('h-a')]);
    expect(remote.markReadCalls, [
      ['a'],
    ]);
    expect(tileOf(tester, 'b').read, isFalse);

    // Once what it opened has gone, rows open again.
    pages.single.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text(titleOf('b')));
    await tester.pumpAndSettle();

    expect(opened, [
      const HouseholdTarget('h-a'),
      const HouseholdTarget('h-b'),
    ]);
    expect(remote.markReadCalls, [
      ['a'],
      ['b'],
    ]);
    pages.last.complete();
  });

  testWidgets('a page a row opened that goes without completing its future '
      'lets rows open again', (tester) async {
    late NavigatorState navigator;
    final routes = <Route<void>>[];
    remote
      ..scriptPages([
        page([joined('a'), joined('b')]),
      ])
      ..scriptMarkRead([null, null]);

    await tester.pumpWidget(
      hostScreen(
        NotificationsScreen(
          remote: remote,
          onOpen: (context, target) {
            opened.add(target);
            navigator = Navigator.of(context);
            final route = MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('opened page')),
            );
            routes.add(route);
            navigator.push(route);
            // As a push the router takes away answers: never.
            return Completer<void>().future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(titleOf('a')));
    await tester.pumpAndSettle();
    expect(find.text('opened page'), findsOneWidget);

    // Taken away, not popped, as the browser's Back or a `go` does.
    navigator.removeRoute(routes.single);
    await tester.pumpAndSettle();
    expect(find.text('opened page'), findsNothing);

    await tester.tap(find.text(titleOf('b')));
    await tester.pumpAndSettle();

    expect(opened, [
      const HouseholdTarget('h-a'),
      const HouseholdTarget('h-b'),
    ]);
    expect(routes, hasLength(2));
  });

  testWidgets("a plain row's Mark read marks it read without onOpen", (
    tester,
  ) async {
    remote
      ..scriptPages([
        page([unknown('odd')]),
      ])
      ..scriptMarkRead([null]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    // A plain row opens nothing.
    await tester.tap(find.text(plainTitle));
    await tester.pumpAndSettle();
    expect(remote.markReadCalls, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Mark read'));
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
    expect(remote.markReadCalls, [
      ['odd'],
    ]);
    expect(tileOf(tester, 'odd').read, isTrue);
    expect(find.widgetWithText(TextButton, 'Mark read'), findsNothing);
  });

  group('Mark all read', () {
    for (final width in [320.0, 700.0, 1200.0]) {
      testWidgets('sits in an end-aligned row above the list, at every '
          'width: ${width.toInt()}dp', (tester) async {
        useViewSize(tester, Size(width, 800));
        remote.scriptPages([
          page([joined('a'), joined('b', read: true)]),
        ]);

        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();

        expect(markAll(), findsOneWidget);
        // In the page, never in the app bar, whatever the width.
        expect(
          find.descendant(of: find.byType(AppBar), matching: markAll()),
          findsNothing,
        );
        final button = tester.getRect(markAll());
        final first = tester.getRect(row('a'));
        expect(button.bottom, lessThanOrEqualTo(first.top));
        // At the list's end edge.
        expect(button.right, moreOrLessEquals(first.right, epsilon: 0.5));
        expect(button.left, greaterThan(first.left));
      });
    }

    testWidgets('shows only while a row is unread, and asks for no '
        'confirmation', (tester) async {
      final count = countCubit();
      remote
        // Read as the page opens, and again once all are marked read.
        ..scriptUnreadCounts([2, 0])
        ..scriptPages([
          page([joined('a'), unknown('odd'), joined('b', read: true)]),
        ])
        ..scriptMarkAllRead([null]);

      await tester.pumpWidget(screen(count: count));
      await tester.pumpAndSettle();
      expect(markAll(), findsOneWidget);

      await tester.tap(markAll());
      await tester.pump();
      expect(find.byType(Dialog), findsNothing);
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(remote.markAllReadCalls, 1);
      for (final id in ['a', 'odd', 'b']) {
        expect(tileOf(tester, id).read, isTrue, reason: id);
      }
      // Nothing unread is left to mark.
      expect(markAll(), findsNothing);
      expect(count.state.unread, 0);
    });

    testWidgets('is not offered when every row is read', (tester) async {
      remote.scriptPages([
        page([joined('a', read: true), unknown('odd', read: true)]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(row('a'), findsOneWidget);
      expect(markAll(), findsNothing);
    });

    testWidgets('stays, inert and named for its pass, while marking', (
      tester,
    ) async {
      final answer = Completer<void>();
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([answer.future]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pump();

      expect(markAll(), findsOneWidget);
      expect(
        tester.widget<BgeInertButton>(markAll()).inert,
        isTrue,
      );
      expect(find.text('Marking all read\u{2026}'), findsOneWidget);

      await tester.tap(markAll());
      await tester.pump();
      expect(remote.markAllReadCalls, 1);

      answer.complete();
      await tester.pumpAndSettle();
      expect(markAll(), findsNothing);
    });

    testWidgets('a failed mark all shows a banner in the footer', (
      tester,
    ) async {
      final count = countCubit();
      remote
        ..scriptUnreadCounts([1])
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([offline]);

      await tester.pumpWidget(screen(count: count));
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pumpAndSettle();

      expectFooterBanner(
        tester,
        markAllFailed(),
        "Couldn't mark your notifications read. Check your connection, "
        'then try again.',
      );
      // The rows are as they were, so it can be tried again.
      expect(tileOf(tester, 'a').read, isFalse);
      expect(markAll(), findsOneWidget);
      expect(count.state.unread, 1);
    });

    testWidgets('a refused mark all says the server refused', (tester) async {
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([refused]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pumpAndSettle();

      expectFooterBanner(
        tester,
        markAllFailed(),
        "The server wouldn't mark your notifications read.",
      );
    });

    testWidgets('a repeat of the failure is a new banner, so it is heard '
        'again', (tester) async {
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([offline, offline]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pumpAndSettle();
      final first = tester.state(
        find.descendant(
          of: markAllFailed(),
          matching: find.byType(BgeInlineBanner),
          matchRoot: true,
        ),
      );

      await tester.tap(markAll());
      await tester.pumpAndSettle();

      expect(markAllFailed(), findsOneWidget);
      final second = tester.state(
        find.descendant(
          of: markAllFailed(),
          matching: find.byType(BgeInlineBanner),
          matchRoot: true,
        ),
      );
      expect(identical(first, second), isFalse);
    });

    testWidgets('its banner stays until the next mark all answers, which '
        'retires it', (tester) async {
      final answer = Completer<void>();
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([offline, answer.future]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pumpAndSettle();
      expect(markAllFailed(), findsOneWidget);

      await tester.tap(markAll());
      await tester.pump();
      // Not as the next one starts: only once it answers.
      expect(markAllFailed(), findsOneWidget);

      answer.complete();
      await tester.pumpAndSettle();
      expect(markAllFailed(), findsNothing);
    });

    testWidgets('its banner goes once nothing is left unread', (tester) async {
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([offline])
        ..scriptMarkRead([null]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pumpAndSettle();
      expect(markAllFailed(), findsOneWidget);

      await tester.tap(find.text(titleOf('a')));
      await tester.pumpAndSettle();

      expect(markAll(), findsNothing);
      expect(markAllFailed(), findsNothing);
    });

    testWidgets('Dismiss takes its banner away, and focus on it goes to '
        'Mark all read', (tester) async {
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([offline]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pumpAndSettle();

      buttonFocus(tester, markAllFailed()).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(markAllFailed(), findsNothing);
      expect(buttonFocus(tester, markAll()).hasPrimaryFocus, isTrue);
    });

    testWidgets('once nothing is unread, focus on it waits on the title', (
      tester,
    ) async {
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([null]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      buttonFocus(tester, markAll()).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(markAll(), findsNothing);
      expect(primaryFocusLabel(), 'Notifications heading');
    });

    testWidgets('a failed mark all keeps focus on it', (tester) async {
      remote
        ..scriptPages([
          page([joined('a')]),
        ])
        ..scriptMarkAllRead([offline]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      final focus = buttonFocus(tester, markAll())..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(markAll(), findsOneWidget);
      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets('offline, it is disabled and says why', (tester) async {
      remote.scriptPages([
        page([joined('a')]),
      ]);

      await tester.pumpWidget(screen(offline: true));
      await tester.pumpAndSettle();

      expect(markAll(), findsOneWidget);
      expect(tester.widget<BgeInertButton>(markAll()).onPressed, isNull);
      expect(
        find.ancestor(of: markAll(), matching: find.byType(BgeOnlineOnly)),
        findsOneWidget,
      );
      expect(find.text(onlineOnlyCopy), findsOneWidget);
    });
  });

  group('refresh', () {
    testWidgets('pull-to-refresh and the refresh button both refresh', (
      tester,
    ) async {
      final count = countCubit();
      remote
        ..scriptUnreadCounts([1, 2, 3])
        ..scriptPages([
          page([joined('a')]),
          page([joined('b'), joined('a')]),
          page([joined('c'), joined('b'), joined('a')]),
        ]);

      await tester.pumpWidget(screen(count: count));
      await tester.pumpAndSettle();
      // The page read the count as it opened.
      expect(remote.fetchUnreadCountCalls, 1);

      await pull(tester);
      await tester.pumpAndSettle();
      expect(remote.fetchPageCalls, hasLength(2));
      expect(row('b'), findsOneWidget);
      expect(remote.fetchUnreadCountCalls, 2);
      expect(count.state.unread, 2);

      expect(
        find.descendant(of: find.byType(AppBar), matching: refreshButton()),
        findsOneWidget,
      );
      await tester.tap(refreshButton());
      await tester.pumpAndSettle();
      expect(remote.fetchPageCalls, hasLength(3));
      expect(row('c'), findsOneWidget);
      expect(remote.fetchUnreadCountCalls, 3);
      expect(count.state.unread, 3);

      // Each read the first page.
      expect(remote.fetchPageCalls.map((call) => call.cursor), [
        null,
        null,
        null,
      ]);
    });

    testWidgets("a pull's spinner holds until the pass ends", (tester) async {
      final second = Completer<NotificationPage>();
      remote.scriptPages([
        page([joined('a')]),
        second.future,
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await pull(tester);

      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      // The button says the same pass is running.
      expect(
        tester
            .widget<BgeRefreshButton>(find.byType(BgeRefreshButton))
            .refreshing,
        isTrue,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      second.complete(page([joined('b'), joined('a')]));
      await tester.pumpAndSettle();

      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(row('b'), findsOneWidget);
    });

    testWidgets('a pull from the error state loads', (tester) async {
      remote.scriptPages([
        offline,
        page([joined('a')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.byType(BgeErrorState), findsOneWidget);

      await pull(tester);
      await tester.pumpAndSettle();

      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(row('a'), findsOneWidget);
    });

    testWidgets('without a count in context, a refresh still reads the list', (
      tester,
    ) async {
      remote.scriptPages([
        page([joined('a')]),
        page([joined('b')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(refreshButton());
      await tester.pumpAndSettle();

      expect(row('b'), findsOneWidget);
      expect(remote.fetchUnreadCountCalls, 0);
    });

    testWidgets('a failed refresh keeps the rows, under a refresh banner in '
        'the header', (tester) async {
      remote.scriptPages([
        page([joined('a')]),
        offline,
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(refreshFailed(), findsNothing);
      await tester.tap(refreshButton());
      await tester.pumpAndSettle();

      expect(row('a'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(refreshFailed(), findsOneWidget);
      expect(
        tester.widget<BgeRefreshBanner>(refreshFailed()).failedMessage,
        "Couldn't refresh your notifications. They may be out of date.",
      );
      expect(
        find.text(
          "Couldn't refresh your notifications. They may be out of date.",
        ),
        findsOneWidget,
      );
      // Above the rows, in the page's header.
      expect(
        tester.getRect(refreshFailed()).bottom,
        lessThanOrEqualTo(tester.getRect(row('a')).top),
      );
      expect(
        find.descendant(
          of: find.byType(SliverEnsureSemantics),
          matching: refreshFailed(),
        ),
        findsOneWidget,
      );
    });

    testWidgets("the refresh banner's Try again refreshes, and a refresh "
        'that works retires it', (tester) async {
      final count = countCubit();
      final third = Completer<NotificationPage>();
      remote
        ..scriptUnreadCounts([1, 1, 2])
        ..scriptPages([
          page([joined('a')]),
          offline,
          third.future,
        ]);

      await tester.pumpWidget(screen(count: count));
      await tester.pumpAndSettle();
      await tester.tap(refreshButton());
      await tester.pumpAndSettle();
      expect(refreshFailed(), findsOneWidget);

      await tester.tap(find.byKey(NotificationsScreen.refreshRetryKey));
      await tester.pump();
      // It says the pass it started is running.
      expect(refreshFailed(), findsOneWidget);
      expect(
        tester.widget<BgeRefreshBanner>(refreshFailed()).refreshing,
        isTrue,
      );
      expect(remote.fetchPageCalls, hasLength(3));
      expect(remote.fetchUnreadCountCalls, 3);

      third.complete(page([joined('b'), joined('a')]));
      await tester.pumpAndSettle();

      expect(row('b'), findsOneWidget);
      expect(refreshFailed(), findsNothing);
    });

    testWidgets("focus on the refresh banner's Try again goes to the title "
        'when the refresh works and the banner goes', (tester) async {
      remote.scriptPages([
        page([joined('a')]),
        offline,
        page([joined('b'), joined('a')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(refreshButton());
      await tester.pumpAndSettle();
      final retry = find.byKey(NotificationsScreen.refreshRetryKey);
      buttonFocus(tester, retry).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(row('b'), findsOneWidget);
      expect(refreshFailed(), findsNothing);
      expect(primaryFocusLabel(), 'Notifications heading');
    });

    testWidgets('a refresh that fails again keeps the banner', (tester) async {
      remote.scriptPages([
        page([joined('a')]),
        offline,
        refused,
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(refreshButton());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NotificationsScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(refreshFailed(), findsOneWidget);
      expect(
        tester.widget<BgeRefreshBanner>(refreshFailed()).refreshing,
        isFalse,
      );
    });
  });

  group('Load more', () {
    testWidgets('appears with a cursor and appends', (tester) async {
      remote.scriptPages([
        page([joined('a'), joined('b')], nextCursor: 'c-1'),
        page([joined('b'), joined('c')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(loadMore(), findsOneWidget);
      expect(find.text('Load more'), findsOneWidget);

      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();

      expect(remote.fetchPageCalls.last.cursor, 'c-1');
      // Below the rows already shown, each once.
      for (final id in ['a', 'b', 'c']) {
        expect(row(id), findsOneWidget);
      }
      expect(
        tester.getTopLeft(row('c')).dy,
        greaterThan(tester.getTopLeft(row('b')).dy),
      );
      // The count grows as pages arrive.
      expect(semanticChildCount(tester), 3);
      // The last page has no cursor: nothing more to load.
      expect(loadMore(), findsNothing);
    });

    testWidgets('is not offered without a cursor', (tester) async {
      remote.scriptPages([
        page([joined('a')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(row('a'), findsOneWidget);
      expect(loadMore(), findsNothing);
    });

    testWidgets('a failed Load more shows a banner in the footer and keeps '
        'the button', (tester) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'c-1'),
        offline,
        page([joined('b')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();

      expectFooterBanner(
        tester,
        loadMoreFailed(),
        "Couldn't load more notifications. Check your connection, then "
        'choose Load more.',
      );
      expect(row('a'), findsOneWidget);
      expect(loadMore(), findsOneWidget);

      // And it can be tried again, from the same cursor. The one that works
      // retires the banner.
      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();
      expect(remote.fetchPageCalls.map((call) => call.cursor), [
        null,
        'c-1',
        'c-1',
      ]);
      expect(row('b'), findsOneWidget);
      expect(loadMoreFailed(), findsNothing);
    });

    testWidgets('the last page hands focus on it to the first row it added', (
      tester,
    ) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'c-1'),
        page([joined('b'), joined('c')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      buttonFocus(tester, loadMore()).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(loadMore(), findsNothing);
      expect(rowHasFocus(tester, 'b'), isTrue);
    });

    testWidgets('a last page that adds no row hands focus on it to the '
        'title', (tester) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'c-1'),
        // Only a row already shown.
        page([joined('a')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      buttonFocus(tester, loadMore()).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(loadMore(), findsNothing);
      expect(primaryFocusLabel(), 'Notifications heading');
    });

    testWidgets('a page with more to come keeps focus on it', (tester) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'c-1'),
        page([joined('b')], nextCursor: 'c-2'),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      final focus = buttonFocus(tester, loadMore())..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(row('b'), findsOneWidget);
      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets('a repeat of the failure is a new banner', (tester) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'c-1'),
        offline,
        offline,
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();
      final first = tester.state(
        find.descendant(
          of: loadMoreFailed(),
          matching: find.byType(BgeInlineBanner),
          matchRoot: true,
        ),
      );

      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();

      final second = tester.state(
        find.descendant(
          of: loadMoreFailed(),
          matching: find.byType(BgeInlineBanner),
          matchRoot: true,
        ),
      );
      expect(identical(first, second), isFalse);
    });

    testWidgets('a refresh that works retires its banner', (tester) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'c-1'),
        offline,
        page([joined('z'), joined('a')], nextCursor: 'c-2'),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();
      expect(loadMoreFailed(), findsOneWidget);

      await tester.tap(refreshButton());
      await tester.pumpAndSettle();

      expect(row('z'), findsOneWidget);
      expect(loadMoreFailed(), findsNothing);
    });

    testWidgets('Dismiss takes its banner away, and focus on it goes to '
        'Load more', (tester) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'c-1'),
        offline,
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();

      buttonFocus(tester, loadMoreFailed()).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(loadMoreFailed(), findsNothing);
      expect(dismissOn(loadMoreFailed()), findsNothing);
      expect(buttonFocus(tester, loadMore()).hasPrimaryFocus, isTrue);
    });

    testWidgets('a banner for each, stacked in the footer', (tester) async {
      remote
        ..scriptPages([
          page([joined('a')], nextCursor: 'c-1'),
          offline,
        ])
        ..scriptMarkAllRead([offline]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(markAll());
      await tester.pumpAndSettle();
      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();

      expect(markAllFailed(), findsOneWidget);
      expect(loadMoreFailed(), findsOneWidget);
      expect(
        tester.getRect(markAllFailed()).bottom,
        lessThanOrEqualTo(tester.getRect(loadMoreFailed()).top),
      );
    });

    testWidgets('a refused Load more points to a refresh', (tester) async {
      remote.scriptPages([
        page([joined('a')], nextCursor: 'bad'),
        refused,
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.ensureVisible(loadMore());
      await tester.tap(loadMore());
      await tester.pumpAndSettle();

      expectFooterBanner(
        tester,
        loadMoreFailed(),
        "The server wouldn't load more notifications. Refresh to start "
        'again from the newest.',
      );
    });
  });

  group('a failed load', () {
    testWidgets('offline load failure shows BgeErrorState with '
        'Icons.cloud_off_outlined and Retry', (tester) async {
      remote.scriptPages([
        offline,
        page([joined('a')]),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      final failed = find.descendant(
        of: find.byType(BgeStateSliver),
        matching: find.byKey(NotificationsScreen.failedKey),
      );
      expect(failed, findsOneWidget);
      final state = tester.widget<BgeErrorState>(failed);
      expect(state.icon, Icons.cloud_off_outlined);
      expect(state.title, "Couldn't load your notifications");
      expect(state.body, 'Check your connection, then try again.');
      expect(state.retryLabel, 'Try again');
      expect(markAll(), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(remote.fetchPageCalls, hasLength(2));
      expect(row('a'), findsOneWidget);
      expect(find.byType(BgeErrorState), findsNothing);
    });

    testWidgets('Try again hands focus to the title as it goes', (
      tester,
    ) async {
      remote.scriptPages([offline, Completer<NotificationPage>().future]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(find.byKey(NotificationsScreen.loadingKey), findsOneWidget);
      expect(primaryFocusLabel(), 'Notifications heading');
    });

    testWidgets('a refused load says the server refused', (tester) async {
      remote.scriptPages([refused]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(
        tester.widget<BgeErrorState>(find.byType(BgeErrorState)).body,
        "The server wouldn't send your notifications. If trying again "
        "doesn't help, tell the server's admin.",
      );
    });
  });

  testWidgets('a count in context is refreshed as the page opens', (
    tester,
  ) async {
    final count = countCubit();
    remote
      ..scriptUnreadCounts([7])
      ..scriptPages([page(const [])]);

    await tester.pumpWidget(screen(count: count));
    await tester.pumpAndSettle();

    expect(remote.fetchUnreadCountCalls, 1);
    expect(count.state.unread, 7);
  });

  testWidgets('a new remote is a new list', (tester) async {
    remote.scriptPages([
      page([joined('a')]),
    ]);
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(row('a'), findsOneWidget);

    remote = FakeNotificationRemote()
      ..scriptPages([
        page([joined('z')]),
      ]);
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    expect(row('a'), findsNothing);
    expect(row('z'), findsOneWidget);
  });

  group('accessibility audit', () {
    // Names the screen for tool/check_a11y_audit.dart: NotificationsScreen.
    Widget Function(ThemeData) screenWith(
      void Function() seed, {
      bool offline = false,
    }) => (theme) {
      seed();
      return screen(theme: theme, offline: offline);
    };

    void rows() => remote.scriptPages([
      page([
        joined('a'),
        unknown('odd'),
        joined('b', read: true),
      ], nextCursor: 'c-1'),
    ]);

    auditScreen(
      'loaded, with Mark all read',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(markAll(), findsOneWidget);
      },
    );

    auditScreen(
      'loaded, scrolled to Load more',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await scrollListToEnd(tester, loadMore(), mustScroll: false);
      },
    );

    auditScreen(
      'offline, Mark all read waits for a connection',
      build: screenWith(rows, offline: true),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        // One reason under Mark all read, one under the plain row's Mark
        // read.
        expect(find.text(onlineOnlyCopy), findsNWidgets(2));
      },
    );

    auditScreen(
      'Mark all read and Load more failed, in the footer',
      build: screenWith(() {
        rows();
        remote
          ..scriptMarkAllRead([offline])
          ..scriptPages([offline]);
      }),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await tester.tap(markAll());
        await tester.pumpAndSettle();
        await scrollListToEnd(tester, loadMore(), mustScroll: false);
        await tester.tap(loadMore());
        await tester.pumpAndSettle();
        expect(markAllFailed(), findsOneWidget);
        expect(loadMoreFailed(), findsOneWidget);
        await scrollPageToTop(tester);
      },
    );

    auditScreen(
      'refresh failed',
      build: screenWith(() {
        rows();
        remote.scriptPages([offline]);
      }),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await tester.tap(refreshButton());
        await tester.pumpAndSettle();
        expect(refreshFailed(), findsOneWidget);
      },
    );

    auditScreen(
      'empty',
      build: screenWith(() => remote.scriptPages([page(const [])])),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(NotificationsScreen.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'load failed',
      build: screenWith(() => remote.scriptPages([offline])),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(NotificationsScreen.failedKey), findsOneWidget);
      },
    );

    auditScreen(
      'loading',
      build: screenWith(
        () => remote.scriptPages([Completer<NotificationPage>().future]),
      ),
      settle: false,
      arrange: (tester) async {
        expect(find.byKey(NotificationsScreen.loadingKey), findsOneWidget);
      },
    );
  });
}
