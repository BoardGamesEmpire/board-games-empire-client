import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:notifications/l10n/notifications_localizations_en.dart';
import 'package:notifications/notifications.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

final _l10n = NotificationsLocalizationsEn();

const _title = 'Ana invited you to The Smiths';

const _opens = NotificationPresentation(
  icon: Icons.mail_outline,
  title: _title,
  target: InviteInboxTarget(),
);

const _plain = NotificationPresentation(
  icon: Icons.notifications_none,
  title: _title,
);

final _createdAt = DateTime.utc(2026, 11, 27, 15, 4);

Widget _host(Widget tile) => MaterialApp(
  theme: BgeTheme.light(),
  localizationsDelegates: NotificationsLocalizations.localizationsDelegates,
  supportedLocales: NotificationsLocalizations.supportedLocales,
  home: Scaffold(body: ListView(children: [tile])),
);

/// The row's one merged node, found from the title it carries.
SemanticsData _rowNode(WidgetTester tester) =>
    tester.getSemantics(find.text(_title)).getSemanticsData();

FontWeight? _titleWeight(WidgetTester tester) => tester
    .renderObject<RenderParagraph>(find.text(_title))
    .text
    .style!
    .fontWeight;

Finder get _markRead =>
    find.widgetWithText(TextButton, _l10n.notificationMarkRead);

void main() {
  testWidgets('an unread tile is announced as unread', (tester) async {
    final semantics = tester.ensureSemantics();
    var opened = 0;
    await tester.pumpWidget(
      _host(
        NotificationTile(
          presentation: _opens,
          read: false,
          createdAt: _createdAt,
          onOpen: () => opened++,
        ),
      ),
    );

    final node = _rowNode(tester);
    expect(node.label, contains(_l10n.notificationUnreadLabel));
    expect(node.label, contains(_title));
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    expect(_titleWeight(tester), FontWeight.bold);
    expect(_markRead, findsNothing);

    // The whole tile is the tap target, not only its title.
    await tester.tap(find.byType(NotificationTile));
    expect(opened, 1);
    semantics.dispose();
  });

  testWidgets('a read tile is not', (tester) async {
    final semantics = tester.ensureSemantics();
    var opened = 0;
    await tester.pumpWidget(
      _host(
        NotificationTile(
          presentation: _opens,
          read: true,
          createdAt: _createdAt,
          onOpen: () => opened++,
        ),
      ),
    );

    final node = _rowNode(tester);
    expect(node.label, isNot(contains(_l10n.notificationUnreadLabel)));
    expect(node.label, contains(_title));
    expect(_titleWeight(tester), isNot(FontWeight.bold));

    // A read row still opens what it's about.
    await tester.tap(find.text(_title));
    expect(opened, 1);
    semantics.dispose();
  });

  testWidgets('a plain unread tile offers Mark read and no tap', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var opened = 0;
    var marked = 0;
    await tester.pumpWidget(
      _host(
        NotificationTile(
          presentation: _plain,
          read: false,
          createdAt: _createdAt,
          onOpen: () => opened++,
          onMarkRead: () => marked++,
        ),
      ),
    );

    expect(_rowNode(tester).hasAction(SemanticsAction.tap), isFalse);
    expect(_rowNode(tester).label, contains(_l10n.notificationUnreadLabel));
    expect(_markRead, findsOneWidget);

    await tester.tap(find.text(_title));
    expect(opened, 0);

    await tester.tap(_markRead);
    expect(marked, 1);
    expect(opened, 0);

    // The button is a node of its own, outside the row's.
    final button = tester.getSemantics(_markRead).getSemanticsData();
    expect(button.label, _l10n.notificationMarkRead);
    expect(button.hasAction(SemanticsAction.tap), isTrue);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  group('offline', () {
    const reason = "Available when you're online";

    Widget offlineHost(Widget tile, {required bool offline}) => _host(
      BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: reason,
        child: tile,
      ),
    );

    testWidgets('a plain row disables Mark read and says why, a direct '
        'write (#475)', (tester) async {
      final semantics = tester.ensureSemantics();
      var marked = 0;
      Widget tile({required bool offline}) => offlineHost(
        NotificationTile(
          presentation: _plain,
          read: false,
          createdAt: _createdAt,
          onOpen: () {},
          onMarkRead: () => marked++,
        ),
        offline: offline,
      );
      await tester.pumpWidget(tile(offline: true));

      final button = tester.widget<TextButton>(_markRead);
      expect(button.onPressed, isNull);
      expect(find.byType(BgeOnlineOnlyNote), findsOneWidget);
      expect(find.text(reason), findsOneWidget);
      final node = tester.getSemantics(_markRead).getSemanticsData();
      expect(node.hint, reason);
      expect(node.label, _l10n.notificationMarkRead);

      await tester.tap(_markRead, warnIfMissed: false);
      expect(marked, 0);

      // Back online: the button works again and the note goes.
      await tester.pumpWidget(tile(offline: false));
      expect(tester.widget<TextButton>(_markRead).onPressed, isNotNull);
      expect(find.text(reason), findsNothing);
      await tester.tap(_markRead);
      expect(marked, 1);
      semantics.dispose();
    });

    testWidgets('a row with a target still opens: opening is not a write', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        offlineHost(
          NotificationTile(
            presentation: _opens,
            read: false,
            createdAt: _createdAt,
            onOpen: () => opened++,
          ),
          offline: true,
        ),
      );

      expect(find.text(reason), findsNothing);
      await tester.tap(find.byType(NotificationTile));
      expect(opened, 1);
    });
  });

  testWidgets('a plain read tile offers nothing', (tester) async {
    final semantics = tester.ensureSemantics();
    var opened = 0;
    await tester.pumpWidget(
      _host(
        NotificationTile(
          presentation: _plain,
          read: true,
          createdAt: _createdAt,
          onOpen: () => opened++,
          onMarkRead: () {},
        ),
      ),
    );

    expect(_markRead, findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(_rowNode(tester).hasAction(SemanticsAction.tap), isFalse);

    await tester.tap(find.text(_title));
    expect(opened, 0);
    semantics.dispose();
  });

  testWidgets('the date reads from the ARB format', (tester) async {
    await tester.pumpWidget(
      _host(
        NotificationTile(
          presentation: _opens,
          read: false,
          createdAt: _createdAt,
          onOpen: () {},
        ),
      ),
    );

    // Shown in the device's time zone: the server sends UTC.
    final local = _createdAt.toLocal();
    final expected =
        '${DateFormat.yMMMd('en').format(local)} at '
        '${DateFormat.jm('en').format(local)}';
    expect(_l10n.notificationReceivedAt(local, local), expected);
    expect(find.text(expected), findsOneWidget);
  });

  group('a quote', () {
    const quote = 'connect ECONNREFUSED 10.0.0.7:443 — retrying';
    const quoted = NotificationPresentation(
      icon: Icons.cloud_off_outlined,
      title: _title,
      quote: quote,
      target: InviteInboxTarget(),
    );

    testWidgets("shows verbatim among the row's lines, and a tap on it "
        'opens the row', (tester) async {
      final semantics = tester.ensureSemantics();
      var opened = 0;
      await tester.pumpWidget(
        _host(
          NotificationTile(
            presentation: quoted,
            read: false,
            createdAt: _createdAt,
            onOpen: () => opened++,
          ),
        ),
      );

      expect(find.text(quote), findsOneWidget);
      // One node with the rest of the row, and no region of its own: on a
      // touch platform the app leaves text unselectable (#322).
      expect(_rowNode(tester).label, contains(quote));
      expect(find.byType(SelectableRegion), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text(quote),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text(quote));
      expect(opened, 1);
      semantics.dispose();
    });

    testWidgets('is cut to quoteMaxLines', (tester) async {
      await tester.pumpWidget(
        _host(
          NotificationTile(
            presentation: quoted,
            read: false,
            createdAt: _createdAt,
            onOpen: () {},
            quoteMaxLines: 2,
          ),
        ),
      );

      final text = tester.widget<Text>(find.text(quote));
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets("on a pointer platform, the app's selection region copies it, "
        'and a click on it still opens the row', (tester) async {
      var opened = 0;
      useViewSize(tester, const Size(1280, 800));
      await tester.pumpWidget(
        MaterialApp(
          theme: pointerPlatformTheme(),
          builder: underSelectionRegion,
          localizationsDelegates:
              NotificationsLocalizations.localizationsDelegates,
          supportedLocales: NotificationsLocalizations.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: [
                NotificationTile(
                  presentation: quoted,
                  read: false,
                  createdAt: _createdAt,
                  onOpen: () => opened++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // The app's region alone: the quote opens no scope of its own.
      expect(
        find.ancestor(
          of: find.text(quote),
          matching: find.byType(SelectableRegion),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text(quote), kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapTimeout);
      expect(opened, 1);

      final copies = captureClipboardCopies();
      final rect = tester.getRect(find.text(quote));
      await mouseDrag(
        tester,
        rect.centerLeft + const Offset(1, 0),
        rect.centerRight - const Offset(1, 0),
      );
      await sendCopyShortcut(tester);
      expect(copies, isNotEmpty);
      expect(copies.last, contains('ECONNREFUSED'));
      expect(opened, 1, reason: 'a drag to select opens nothing');
    });
  });
}
