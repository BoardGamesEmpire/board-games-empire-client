import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/notifications.dart';
import 'package:ui/ui.dart';

import '../support/fake_notification_remote.dart';
import '../support/harness.dart';

/// The bell's preview (#475): the five latest notifications in the shared
/// pop-up, with Mark all read and See all.
void main() {
  late FakeNotificationRemote remote;
  late NotificationCountCubit count;
  late List<NotificationTarget> opened;
  late int seeAll;

  setUp(() {
    remote = FakeNotificationRemote();
    count = NotificationCountCubit(remote);
    addTearDown(count.close);
    opened = [];
    seeAll = 0;
  });

  const offline = NotificationTransientException('offline');
  const refused = NotificationPermanentException('no', statusCode: 400);

  /// A phone, where the preview is a sheet.
  const phone = Size(390, 844);

  /// A window from the medium class up, where it is a dialog.
  const wide = Size(840, 900);

  /// A notification that opens its household: "Bo joined Home <id>".
  UserNotification joined(String id, {bool read = false}) => UserNotification(
    id: id,
    type: 'HouseholdInviteAccepted',
    payload: {
      'householdId': 'h-$id',
      'householdName': 'Home $id',
      'memberName': 'Bo',
    },
    read: read,
    readAt: read ? DateTime.utc(2026, 11, 26, 13) : null,
    createdAt: DateTime.utc(2026, 11, 26, 12),
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

  NotificationPage page(
    List<UserNotification> items, {
    String? nextCursor,
  }) => NotificationPage(items: items, nextCursor: nextCursor);

  /// A page that opens the preview from its button, as the bell does.
  /// [onOpen] and [onSeeAll] default to recording what was asked for.
  Widget opener({
    Future<void> Function(BuildContext context, NotificationTarget target)?
    onOpen,
    VoidCallback? onSeeAll,
  }) => Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => TextButton(
          onPressed: () => unawaited(
            showNotificationsPreview(
              context,
              remote: remote,
              count: count,
              onOpen: onOpen ?? (_, target) async => opened.add(target),
              onSeeAll: onSeeAll ?? () => seeAll++,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  /// Opens the preview over a page in a window of [size], with the server's
  /// unread count at [unread], and then at each of [recount] as the count is
  /// read again after a mark. It settles, unless [settle] is false, for a
  /// read that is held: then it pumps past the entrance.
  ///
  /// A null [size] leaves the view as it is, for an audit cell, which sets
  /// its own.
  Future<void> open(
    WidgetTester tester, {
    Size? size = phone,
    int unread = 0,
    List<int> recount = const [],
    bool isOffline = false,
    bool settle = true,
    ThemeData? theme,
    Future<void> Function(BuildContext context, NotificationTarget target)?
    onOpen,
    VoidCallback? onSeeAll,
  }) async {
    if (size != null) useViewSize(tester, size);
    remote.scriptUnreadCounts([unread, ...recount]);
    await tester.pumpWidget(
      hostPopupOpener(
        opener(onOpen: onOpen, onSeeAll: onSeeAll),
        theme: theme,
        offline: isOffline,
      ),
    );
    await tester.tap(find.text('open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Finder preview({bool skipOffstage = true}) => find.byKey(
    NotificationsPreview.contentKey,
    skipOffstage: skipOffstage,
  );
  Finder row(String id) => find.byKey(NotificationsPreview.rowKey(id));
  Finder markAll() => find.byKey(NotificationsPreview.markAllKey);
  Finder markAllFailed() => find.byKey(NotificationsPreview.markAllFailedKey);
  Finder seeAllButton() => find.byKey(NotificationsPreview.seeAllKey);

  /// The [T] inside what [finder] finds: a shared part, keyed by the
  /// surface, draws it.
  T inside<T extends Widget>(WidgetTester tester, Finder finder) =>
      tester.widget<T>(find.descendant(of: finder, matching: find.byType(T)));

  NotificationTile tileOf(WidgetTester tester, String id) =>
      tester.widget<NotificationTile>(
        find.descendant(of: row(id), matching: find.byType(NotificationTile)),
      );

  /// The button under [finder].
  ButtonStyleButton buttonIn(WidgetTester tester, Finder finder) =>
      tester.widget<ButtonStyleButton>(
        find.descendant(
          of: finder,
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
      );

  String? primaryFocusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  testWidgets('shows at most five rows from a page of five', (tester) async {
    remote.scriptPages([
      page([
        joined('n1'),
        joined('n2', read: true),
        joined('n3'),
        unknown('n4'),
        joined('n5', read: true),
      ], nextCursor: 'c-1'),
    ]);

    await open(tester);

    expect(remote.fetchPageCalls, [(cursor: null, limit: 5)]);
    expect(find.byType(NotificationTile), findsNWidgets(5));
    final tops = [
      for (final id in ['n1', 'n2', 'n3', 'n4', 'n5'])
        tester.getTopLeft(row(id)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()), reason: 'newest first');
    expect(tileOf(tester, 'n1').read, isFalse);
    expect(tileOf(tester, 'n2').read, isTrue);
    // A glance: each row's quote is cut to two lines.
    for (final tile in tester.widgetList<NotificationTile>(
      find.byType(NotificationTile),
    )) {
      expect(tile.quoteMaxLines, 2);
    }
    // Rows in a pop-up stay plain (STYLE_GUIDE, List surfaces).
    expect(find.byType(BgeOutlinedRow), findsNothing);
    // The rest is the page's, behind See all: the preview loads no more.
    expect(find.text('Load more'), findsNothing);
    expect(seeAllButton(), findsOneWidget);
  });

  testWidgets('a page longer than five still shows the first five', (
    tester,
  ) async {
    remote.scriptPages([
      page([for (var i = 1; i <= 7; i++) joined('n$i')]),
    ]);

    await open(tester);

    expect(find.byType(NotificationTile), findsNWidgets(5));
    expect(row('n5'), findsOneWidget);
    expect(row('n6'), findsNothing);
  });

  testWidgets('is headed and named Notifications', (tester) async {
    final semantics = tester.ensureSemantics();
    remote.scriptPages([
      page([joined('a')]),
    ]);

    await open(tester);

    final heading = find.descendant(
      of: preview(),
      matching: find.text('Notifications'),
    );
    expect(heading, findsOneWidget);
    final data = tester.getSemantics(heading).getSemanticsData();
    // The level is what iOS and Android read as a heading.
    expect(data.headingLevel, 2);
    expect(data.flagsCollection.isHeader, isTrue);
    // And the pop-up is named for a screen reader as it opens: its content
    // sits in the node that names the route.
    final route = tester.getSemantics(preview()).getSemanticsData();
    expect(route.label, 'Notifications');
    expect(route.flagsCollection.namesRoute, isTrue);
    semantics.dispose();
  });

  testWidgets('reads the unread count again as it opens', (tester) async {
    remote.scriptPages([
      page([joined('a')]),
    ]);

    await open(tester, unread: 7);

    expect(remote.fetchUnreadCountCalls, 1);
    expect(count.state.unread, 7);
  });

  testWidgets('See all calls onSeeAll', (tester) async {
    remote.scriptPages([
      page([joined('a')]),
    ]);
    await open(tester);

    expect(
      find.descendant(of: seeAllButton(), matching: find.text('See all')),
      findsOneWidget,
    );
    await tester.tap(seeAllButton());
    await tester.pump();

    expect(seeAll, 1);
    expect(opened, isEmpty);
  });

  testWidgets(
    'tapping a row calls onOpen and marks it read, and the count goes down',
    (tester) async {
      remote
        ..scriptPages([
          page([joined('a'), joined('b')]),
        ])
        ..scriptMarkRead([null]);
      await open(tester, unread: 3, recount: [2]);
      expect(count.state.unread, 3);

      await tester.tap(find.text(titleOf('a')));
      await tester.pumpAndSettle();

      expect(opened, [const HouseholdTarget('h-a')]);
      expect(remote.markReadCalls, [
        ['a'],
      ]);
      expect(tileOf(tester, 'a').read, isTrue);
      expect(tileOf(tester, 'b').read, isFalse);
      expect(count.state.unread, 2);
    },
  );

  testWidgets("a plain row's Mark read marks it read and opens nothing", (
    tester,
  ) async {
    remote
      ..scriptPages([
        page([unknown('odd')]),
      ])
      ..scriptMarkRead([null]);
    await open(tester, unread: 1, recount: [0]);
    expect(markAll(), findsOneWidget);

    await tester.tap(find.text('Mark read'));
    await tester.pumpAndSettle();

    expect(remote.markReadCalls, [
      ['odd'],
    ]);
    expect(opened, isEmpty);
    expect(seeAll, 0);
    expect(tileOf(tester, 'odd').read, isTrue);
    expect(count.state.unread, 0);
    // Nothing shown is unread now, so there is nothing for Mark all read.
    expect(markAll(), findsNothing);
  });

  group("a plain row's Mark read pressed from the keyboard goes with the row "
      'turned read, and hands focus on (#475)', () {
    /// The node of the control nearest above [finder].
    FocusNode focusOf(WidgetTester tester, Finder finder) =>
        Focus.of(tester.element(finder));

    /// Tabs to the first Mark read and presses Enter on it.
    Future<void> markReadByKeyboard(WidgetTester tester) async {
      final button = focusOf(tester, find.text('Mark read').first);
      for (var i = 0; i < 20 && !button.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(button.hasPrimaryFocus, isTrue, reason: 'Tab reaches it');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    testWidgets('to the next row with a control, past one with none', (
      tester,
    ) async {
      remote
        ..scriptPages([
          page([unknown('odd'), unknown('done', read: true), joined('c')]),
        ])
        ..scriptMarkRead([null]);
      await open(tester, unread: 2, recount: [1]);

      await markReadByKeyboard(tester);

      expect(tileOf(tester, 'odd').read, isTrue);
      expect(find.text('Mark read'), findsNothing);
      expect(focusOf(tester, find.text(titleOf('c'))).hasPrimaryFocus, isTrue);
    });

    testWidgets('to the heading, with no row after it to take it', (
      tester,
    ) async {
      remote
        ..scriptPages([
          page([joined('a'), unknown('odd')]),
        ])
        ..scriptMarkRead([null]);
      await open(tester, unread: 2, recount: [1]);

      await markReadByKeyboard(tester);

      expect(tileOf(tester, 'odd').read, isTrue);
      expect(primaryFocusLabel(), 'Notifications preview heading');
    });
  });

  testWidgets('Mark all read sets the count to zero', (tester) async {
    remote
      ..scriptPages([
        page([joined('a'), joined('b', read: true), joined('c')]),
      ])
      ..scriptMarkAllRead([null]);
    await open(tester, unread: 4, recount: [0]);
    expect(count.state.unread, 4);
    expect(
      find.descendant(of: markAll(), matching: find.text('Mark all read')),
      findsOneWidget,
    );

    await tester.tap(markAll());
    await tester.pumpAndSettle();

    expect(remote.markAllReadCalls, 1);
    expect(count.state.unread, 0);
    expect(tileOf(tester, 'a').read, isTrue);
    expect(tileOf(tester, 'c').read, isTrue);
    // No confirmation, and nothing left for it to mark.
    expect(find.byType(AlertDialog), findsNothing);
    expect(markAll(), findsNothing);
  });

  testWidgets('Mark all read shows only once loaded, with a row unread', (
    tester,
  ) async {
    final first = Completer<NotificationPage>();
    remote.scriptPages([first.future]);
    await open(tester, settle: false);
    expect(find.byKey(NotificationsPreview.loadingKey), findsOneWidget);
    expect(markAll(), findsNothing);

    first.complete(page([joined('a', read: true), joined('b', read: true)]));
    await tester.pumpAndSettle();

    expect(row('a'), findsOneWidget);
    expect(markAll(), findsNothing);
  });

  testWidgets('while Mark all read runs it stays, inert and named for the '
      'pass', (tester) async {
    final marking = Completer<void>();
    remote
      ..scriptPages([
        page([joined('a')]),
      ])
      ..scriptMarkAllRead([marking.future]);
    await open(tester, unread: 1, recount: [0]);

    await tester.tap(markAll());
    await tester.pump();

    expect(markAll(), findsOneWidget);
    expect(
      find.descendant(
        of: markAll(),
        matching: find.text('Marking all read\u{2026}'),
      ),
      findsOneWidget,
    );
    expect(inside<BgeInertButton>(tester, markAll()).inert, isTrue);

    marking.complete();
    await tester.pumpAndSettle();
    expect(markAll(), findsNothing);
  });

  testWidgets('once nothing is unread, focus on Mark all read waits on the '
      'heading', (tester) async {
    remote
      ..scriptPages([
        page([joined('a')]),
      ])
      ..scriptMarkAllRead([null]);
    await open(tester, unread: 1, recount: [0]);
    final button = buttonIn(tester, markAll()).focusNode!;
    for (var i = 0; i < 10 && !button.hasPrimaryFocus; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(button.hasPrimaryFocus, isTrue, reason: 'Tab reaches it');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(markAll(), findsNothing);
    expect(primaryFocusLabel(), 'Notifications preview heading');
  });

  testWidgets('a failed Mark all read says so in a banner in the pop-up, and '
      'the rows show unread again until one works', (tester) async {
    final semantics = tester.ensureSemantics();
    remote
      ..scriptPages([
        page([joined('a'), joined('b', read: true)]),
      ])
      ..scriptMarkAllRead([offline, refused, null]);
    // Only the one that works reads the count again.
    await open(tester, unread: 1, recount: [0]);
    final rowShown = tester.element(row('b'));

    await tester.tap(markAll());
    await tester.pumpAndSettle();

    expect(markAllFailed(), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // The rows stay as they were built as the banner arrives above them.
    expect(tester.element(row('b')), same(rowShown));
    final banner = tester.widget<BgeInlineBanner>(markAllFailed());
    expect(
      banner.message,
      "Couldn't mark your notifications read. Check your connection, then "
      'try again.',
    );
    expect(banner.tone, BgeBannerTone.error);
    expect(banner.announce, isTrue);
    // A live region, reached from inside the banner's merged node.
    final node = tester.getSemantics(
      find.descendant(of: markAllFailed(), matching: find.byType(Icon)).first,
    );
    expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    // In the pop-up, under the button it answers.
    expect(
      find.descendant(of: preview(), matching: markAllFailed()),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(markAllFailed()).dy,
      greaterThan(tester.getBottomLeft(markAll()).dy - 1),
    );
    expect(tileOf(tester, 'a').read, isFalse);
    expect(tileOf(tester, 'b').read, isTrue);
    expect(markAll(), findsOneWidget);
    expect(count.state.unread, 1);

    // A refusal is said in its own words, as a new banner.
    final first = tester.element(markAllFailed());
    await tester.tap(markAll());
    await tester.pumpAndSettle();
    expect(
      tester.widget<BgeInlineBanner>(markAllFailed()).message,
      "The server wouldn't mark your notifications read.",
    );
    expect(tester.element(markAllFailed()), isNot(same(first)));

    // One that works takes the banner away.
    await tester.tap(markAll());
    await tester.pumpAndSettle();
    expect(markAllFailed(), findsNothing);
    expect(count.state.unread, 0);
    semantics.dispose();
  });

  testWidgets("a failed Mark all read's banner goes once nothing shown is "
      'unread, with the button', (tester) async {
    remote
      ..scriptPages([
        page([unknown('odd'), joined('b', read: true)]),
      ])
      ..scriptMarkAllRead([offline])
      ..scriptMarkRead([null]);
    await open(tester, unread: 1, recount: [0]);
    await tester.tap(markAll());
    await tester.pumpAndSettle();
    expect(markAllFailed(), findsOneWidget);
    final rowShown = tester.element(row('b'));

    await tester.tap(find.text('Mark read'));
    await tester.pumpAndSettle();

    expect(markAll(), findsNothing);
    expect(markAllFailed(), findsNothing);
    expect(tester.element(row('b')), same(rowShown));
  });

  testWidgets('offline, Mark all read waits for a connection', (tester) async {
    remote.scriptPages([
      page([joined('a')]),
    ]);

    await open(tester, unread: 1, isOffline: true);

    expect(markAll(), findsOneWidget);
    expect(buttonIn(tester, markAll()).onPressed, isNull);
    expect(
      find.descendant(of: preview(), matching: find.text(onlineOnlyCopy)),
      findsOneWidget,
    );
    // The rows still open: reading one is no direct write to wait for.
    expect(tileOf(tester, 'a').onOpen, isNotNull);
  });

  testWidgets('empty says No notifications yet and still offers See all', (
    tester,
  ) async {
    remote.scriptPages([page(const [])]);
    await open(tester);

    final empty = find.byKey(NotificationsPreview.emptyKey);
    expect(empty, findsOneWidget);
    expect(inside<BgeEmptyState>(tester, empty).title, 'No notifications yet');
    expect(markAll(), findsNothing);

    await tester.tap(seeAllButton());
    await tester.pump();
    expect(seeAll, 1);
  });

  for (final (failure, icon, body) in [
    (
      offline,
      Icons.cloud_off_outlined,
      'Check your connection, then try again.',
    ),
    (
      refused,
      Icons.error_outline,
      "The server wouldn't send your notifications. If trying again doesn't "
          "help, tell the server's admin.",
    ),
  ]) {
    testWidgets('a load that fails ${failure.runtimeType} offers Try again, '
        'and still See all', (tester) async {
      final first = Completer<NotificationPage>();
      remote.scriptPages([
        first.future,
        page([joined('a')]),
      ]);
      await open(tester, settle: false);

      first.completeError(failure);
      await tester.pumpAndSettle();

      final failed = find.byKey(NotificationsPreview.failedKey);
      expect(failed, findsOneWidget);
      final state = inside<BgeErrorState>(tester, failed);
      expect(state.icon, icon);
      expect(state.title, "Couldn't load your notifications");
      expect(state.body, body);
      expect(seeAllButton(), findsOneWidget);
      expect(markAll(), findsNothing);

      // Try again goes as the read starts: focus waits on the heading.
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(primaryFocusLabel(), 'Notifications preview heading');
      await tester.pumpAndSettle();

      expect(row('a'), findsOneWidget);
      expect(remote.fetchPageCalls, [
        (cursor: null, limit: 5),
        (cursor: null, limit: 5),
      ]);
    });
  }

  testWidgets('is a sheet on a compact window and a dialog from medium up', (
    tester,
  ) async {
    remote
      ..scriptPages([
        page([joined('a')]),
        page([joined('a')]),
      ])
      ..scriptUnreadCounts([0]);
    BgePopupForm? form() => BgePopupForm.maybeOf(tester.element(row('a')));

    await open(tester);
    expect(form(), BgePopupForm.sheet);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(preview(), findsNothing);

    useViewSize(tester, wide);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(form(), BgePopupForm.dialog);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    // The form follows the window while it is open, with what it shows
    // kept: no second read.
    useViewSize(tester, phone);
    await tester.pumpAndSettle();
    expect(form(), BgePopupForm.sheet);
    expect(remote.fetchPageCalls, hasLength(2));
  });

  testWidgets('Tab goes from Mark all read through the rows to See all', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    remote.scriptPages([
      page([joined('a'), unknown('odd'), joined('b', read: true)]),
    ]);
    await open(tester, unread: 2);

    final order = await tabOrder(tester);

    expect(order.first, 'Mark all read');
    expect(order[1], startsWith('Unread\n${titleOf('a')}'));
    expect(order[2], 'Mark read');
    expect(order[3], startsWith(titleOf('b')));
    expect(order[4], 'See all');
    semantics.dispose();
  });

  testWidgets('a read that answers while the pop-up leaves is not shown in '
      'it', (tester) async {
    final first = Completer<NotificationPage>();
    remote.scriptPages([first.future]);
    await open(tester, settle: false);

    // Back, as the system's or a barrier tap closes it.
    await tester.binding.handlePopRoute();
    await tester.pump();
    first.completeError(offline);
    await tester.pump(const Duration(milliseconds: 50));

    // Still on its way out, and still as it was: nothing takes focus in it.
    expect(preview(skipOffstage: false), findsOneWidget);
    expect(find.byType(BgeErrorState, skipOffstage: false), findsNothing);
    expect(find.byType(BgeLoadingState, skipOffstage: false), findsOneWidget);

    await tester.pumpAndSettle();
    expect(preview(skipOffstage: false), findsNothing);
  });

  testWidgets('a Mark all read that answers after the pop-up has closed still '
      'clears the count', (tester) async {
    final marking = Completer<void>();
    remote
      ..scriptPages([
        page([joined('a')]),
      ])
      ..scriptMarkAllRead([marking.future]);
    await open(tester, unread: 2, recount: [0]);
    await tester.tap(markAll());
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(preview(skipOffstage: false), findsNothing);
    expect(count.state.unread, 2);

    marking.complete();
    await tester.pump();
    expect(count.state.unread, 0);
  });

  group('a page opened from the preview removes it once it has arrived '
      '(#475)', () {
    /// A page standing in for the one [name] opens.
    Route<void> pageFor(String name) => MaterialPageRoute<void>(
      builder: (_) => Scaffold(appBar: AppBar(), body: Text(name)),
    );

    /// The opener's focus node: the nearest above its words.
    FocusNode openerFocus(WidgetTester tester) =>
        Focus.of(tester.element(find.text('open')));

    testWidgets('See all over a pushed page removes the pop-up once covered, '
        'and Back from the page returns to the screen beneath, not the '
        'pop-up', (tester) async {
      useViewSize(tester, phone);
      remote
        ..scriptUnreadCounts([0])
        ..scriptPages([
          page([joined('a')]),
        ]);
      late BuildContext openerContext;
      await tester.pumpWidget(
        hostPopupOpener(
          Builder(
            builder: (context) {
              openerContext = context;
              return opener(
                onSeeAll: () {
                  seeAll++;
                  Navigator.of(
                    openerContext,
                  ).push(pageFor('All notifications'));
                },
              );
            },
          ),
        ),
      );
      // From the keyboard, so focus has somewhere to come back to.
      final node = openerFocus(tester);
      for (var i = 0; i < 10 && !node.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(node.hasPrimaryFocus, isTrue, reason: 'Tab reaches the opener');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(preview(), findsOneWidget);

      await tester.tap(seeAllButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Left in place while the page slides in over it.
      expect(preview(skipOffstage: false), findsOneWidget);

      await tester.pumpAndSettle();
      expect(seeAll, 1);
      expect(find.text('All notifications'), findsOneWidget);
      // Gone once the page has arrived, not just hidden under it.
      expect(preview(skipOffstage: false), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('All notifications', skipOffstage: false), findsNothing);
      expect(preview(skipOffstage: false), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(openerFocus(tester)));
    });

    /// The app's shape: the opener's page is on the shell's nested
    /// navigator, and the preview over it on the root one, so a page opened
    /// from it arrives beneath it, and the preview goes once the page has
    /// arrived (#414). Until then the preview is on top, where a second
    /// press reaches it. The app's router builds its navigators again on
    /// each push, and the pop-up's builder runs again with them, so a guard
    /// made there would let a second press through.
    Future<void> openOnNestedNavigator(
      WidgetTester tester, {
      required GlobalKey<NavigatorState> nested,
      required ValueNotifier<int> pushes,
      Future<void> Function(BuildContext context, NotificationTarget target)?
      onOpen,
      VoidCallback? onSeeAll,
    }) async {
      useViewSize(tester, phone);
      final observer = BgePopupCoverObserver();
      await tester.pumpWidget(
        ValueListenableBuilder<int>(
          valueListenable: pushes,
          builder: (_, _, _) => hostPopupOpener(
            Navigator(
              key: nested,
              observers: [observer],
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => opener(onOpen: onOpen, onSeeAll: onSeeAll),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(preview(), findsOneWidget);
    }

    testWidgets('See all pressed twice while its page arrives beneath opens '
        'it once, and Back lands where the preview was opened', (
      tester,
    ) async {
      final nested = GlobalKey<NavigatorState>();
      final pushes = ValueNotifier(0);
      addTearDown(pushes.dispose);
      remote
        ..scriptUnreadCounts([0])
        ..scriptPages([
          page([joined('a')]),
        ]);
      await openOnNestedNavigator(
        tester,
        nested: nested,
        pushes: pushes,
        onSeeAll: () {
          seeAll++;
          nested.currentState!.push(pageFor('All notifications'));
          pushes.value++;
        },
      );

      await tester.tap(seeAllButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Arriving beneath the preview, which is still on top.
      expect(find.text('All notifications'), findsOneWidget);
      expect(preview(), findsOneWidget);
      final again = tester.getCenter(seeAllButton());
      expect(
        tester.hitTestOnBinding(again).path.map((entry) => entry.target),
        contains(tester.renderObject(seeAllButton())),
      );
      await tester.tapAt(again);
      await tester.pump();

      expect(seeAll, 1);

      await tester.pumpAndSettle();
      expect(preview(skipOffstage: false), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('All notifications', skipOffstage: false), findsNothing);
      expect(preview(skipOffstage: false), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a row tapped again while its page arrives opens it once and '
        'marks it read once; no other row opens meanwhile', (tester) async {
      final nested = GlobalKey<NavigatorState>();
      final pushes = ValueNotifier(0);
      addTearDown(pushes.dispose);
      remote
        ..scriptUnreadCounts([3, 2])
        ..scriptPages([
          page([joined('a'), joined('b')]),
        ])
        ..scriptMarkRead([null]);
      await openOnNestedNavigator(
        tester,
        nested: nested,
        pushes: pushes,
        onOpen: (context, target) async {
          opened.add(target);
          final pushed = nested.currentState!.push(pageFor('$target'));
          pushes.value++;
          await pushed;
        },
      );

      await tester.tap(find.text(titleOf('a')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(preview(), findsOneWidget);
      await tester.tap(find.text(titleOf('a')));
      await tester.tap(find.text(titleOf('b')));
      await tester.pump();

      expect(opened, [const HouseholdTarget('h-a')]);
      expect(remote.markReadCalls, [
        ['a'],
      ]);

      await tester.pumpAndSettle();
      expect(preview(skipOffstage: false), findsNothing);
      expect(count.state.unread, 2);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(preview(skipOffstage: false), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });

  group('accessibility audit', () {
    /// A row that opens and is unread, a plain row, and one already read.
    void rows() => remote.scriptPages([
      page([joined('a'), unknown('odd'), joined('b', read: true)]),
    ]);

    /// Opens the preview in [theme], as a sheet, or as a dialog in an 840dp
    /// window with [dialog]. A cell keeps only its text scale and theme then.
    Future<void> openIn(
      WidgetTester tester,
      ThemeData theme, {
      required bool dialog,
      bool isOffline = false,
    }) => open(
      tester,
      size: dialog ? wide : null,
      unread: 2,
      theme: theme,
      isOffline: isOffline,
    );

    for (final dialog in [false, true]) {
      final form = dialog ? ' (dialog, 840dp)' : '';

      auditScreen(
        'loaded, with Mark all read$form',
        pump: (tester, theme) {
          rows();
          return openIn(tester, theme, dialog: dialog);
        },
        arrange: (tester) async => expect(markAll(), findsOneWidget),
      );
    }

    auditScreen(
      'loading',
      pump: (tester, theme) {
        // Held for the cell: the spinner never settles.
        remote.scriptPages([Completer<NotificationPage>().future]);
        return open(tester, size: null, theme: theme, settle: false);
      },
      arrange: (tester) async =>
          expect(find.byKey(NotificationsPreview.loadingKey), findsOneWidget),
      settle: false,
    );

    auditScreen(
      'empty',
      pump: (tester, theme) {
        remote.scriptPages([page(const [])]);
        return openIn(tester, theme, dialog: false);
      },
      arrange: (tester) async =>
          expect(find.byKey(NotificationsPreview.emptyKey), findsOneWidget),
    );

    auditScreen(
      'load failed',
      pump: (tester, theme) {
        remote.scriptPages([offline]);
        return openIn(tester, theme, dialog: false);
      },
      arrange: (tester) async =>
          expect(find.byKey(NotificationsPreview.failedKey), findsOneWidget),
    );

    auditScreen(
      'Mark all read failed',
      pump: (tester, theme) {
        rows();
        remote.scriptMarkAllRead([offline]);
        return openIn(tester, theme, dialog: false);
      },
      arrange: (tester) async {
        await tester.tap(markAll());
        await tester.pumpAndSettle();
        expect(markAllFailed(), findsOneWidget);
      },
    );

    auditScreen(
      "offline, Mark all read and a plain row's Mark read wait for a "
      'connection',
      pump: (tester, theme) {
        rows();
        return openIn(tester, theme, dialog: false, isOffline: true);
      },
      // One reason under Mark all read, one under the plain row's Mark read.
      arrange: (tester) async =>
          expect(find.text(onlineOnlyCopy), findsNWidgets(2)),
    );
  });
}
