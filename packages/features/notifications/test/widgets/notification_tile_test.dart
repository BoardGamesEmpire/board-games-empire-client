import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

  // A DataGateway's upstream error (#545). Tests run on Android, a touch
  // platform, where the app's selection region isn't built (#322): the
  // button is the only way to copy it there.
  group('an error quote', () {
    const error = 'connect ECONNREFUSED 10.0.0.7:443 — retrying';
    const failed = NotificationPresentation(
      icon: Icons.power_off_outlined,
      title: _title,
      quote: error,
      quoteIsError: true,
      target: InviteInboxTarget(),
    );

    Finder copyButton() =>
        find.widgetWithText(TextButton, _l10n.notificationCopyError);

    Future<void> pump(
      WidgetTester tester, {
      NotificationPresentation presentation = failed,
      bool offersCopy = true,
      VoidCallback? onOpen,
    }) => tester.pumpWidget(
      _host(
        NotificationTile(
          presentation: presentation,
          read: false,
          createdAt: _createdAt,
          onOpen: onOpen ?? () {},
          offersCopy: offersCopy,
        ),
      ),
    );

    /// Fails every clipboard write, until the test ends.
    void refuseClipboard(WidgetTester tester) {
      final messenger = tester.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'denied');
          }
          return null;
        });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
    }

    testWidgets('Copy error, under the row, copies all of it and says so, '
        'and opens nothing', (tester) async {
      final semantics = tester.ensureSemantics();
      final copies = captureClipboardCopies();
      var opened = 0;
      await pump(tester, onOpen: () => opened++);

      expect(find.byType(SelectableRegion), findsNothing);
      expect(copyButton(), findsOneWidget);
      // Its own node after the row's, not part of the row's tap.
      expect(
        find.descendant(of: find.byType(ListTile), matching: copyButton()),
        findsNothing,
      );
      expect(
        _rowNode(tester).label,
        isNot(contains(_l10n.notificationCopyError)),
      );
      expect(
        tester.getTopLeft(copyButton()).dy,
        greaterThan(tester.getBottomLeft(find.byType(ListTile)).dy - 1),
      );

      await tester.tap(copyButton());
      await tester.pumpAndSettle();

      expect(copies, [error]);
      expect(find.text(_l10n.notificationErrorCopied), findsOneWidget);
      expect(opened, 0);
      semantics.dispose();
    });

    testWidgets('keeps focus through its press, and a second press leaves '
        'one bar', (tester) async {
      final copies = captureClipboardCopies();
      await pump(tester);

      // The button's own node, the nearest Focus above its label.
      final node = Focus.of(
        tester.element(find.text(_l10n.notificationCopyError)),
      )..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(node.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(copies, [error, error]);
      expect(find.text(_l10n.notificationErrorCopied), findsOneWidget);
      expect(node.hasPrimaryFocus, isTrue);
    });

    testWidgets('a copy that fails says so, and raises nothing', (
      tester,
    ) async {
      refuseClipboard(tester);
      await pump(tester);

      await tester.tap(copyButton());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(_l10n.notificationErrorCopyFailed), findsOneWidget);
      expect(find.text(_l10n.notificationErrorCopied), findsNothing);
    });

    testWidgets('a copy that answers after a later one says nothing over '
        "the later one's answer", (tester) async {
      final writes = <Completer<void>>[];
      final messenger = tester.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final write = Completer<void>();
            writes.add(write);
            await write.future;
          }
          return null;
        });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pump(tester);

      await tester.tap(copyButton());
      await tester.pump();
      await tester.tap(copyButton());
      await tester.pump();
      expect(writes, hasLength(2));

      // The second fails first; the first then goes through.
      writes[1].completeError(PlatformException(code: 'denied'));
      await tester.pumpAndSettle();
      writes[0].complete();
      await tester.pumpAndSettle();

      expect(find.text(_l10n.notificationErrorCopyFailed), findsOneWidget);
      expect(find.text(_l10n.notificationErrorCopied), findsNothing);
    });

    testWidgets('works offline: copying is not a write', (tester) async {
      final copies = captureClipboardCopies();
      await tester.pumpWidget(
        _host(
          BgeConnectivityScope(
            offline: true,
            noticeShowing: true,
            onlineOnlyReason: 'offline',
            child: NotificationTile(
              presentation: failed,
              read: false,
              createdAt: _createdAt,
              onOpen: () {},
              offersCopy: true,
            ),
          ),
        ),
      );

      expect(
        tester.widget<TextButton>(copyButton()).onPressed,
        isNotNull,
      );
      await tester.tap(copyButton());
      await tester.pumpAndSettle();
      expect(copies, [error]);
    });

    testWidgets('is not offered where offersCopy is unset, as in the preview', (
      tester,
    ) async {
      await pump(tester, offersCopy: false);

      expect(find.text(error), findsOneWidget);
      expect(copyButton(), findsNothing);
    });

    testWidgets('is not offered for a quote that is not an error', (
      tester,
    ) async {
      await pump(
        tester,
        presentation: const NotificationPresentation(
          icon: Icons.event_busy_outlined,
          title: _title,
          quote: 'Wasserschaden im Keller',
          target: InviteInboxTarget(),
        ),
      );

      expect(find.text('Wasserschaden im Keller'), findsOneWidget);
      expect(copyButton(), findsNothing);
    });

    testWidgets('on a plain unread row, sits above Mark read', (tester) async {
      await pump(
        tester,
        presentation: const NotificationPresentation(
          icon: Icons.power_off_outlined,
          title: _title,
          quote: error,
          quoteIsError: true,
        ),
      );

      expect(copyButton(), findsOneWidget);
      expect(_markRead, findsOneWidget);
      expect(
        tester.getTopLeft(copyButton()).dy,
        lessThan(tester.getTopLeft(_markRead).dy),
      );
    });

    testWidgets('320dp at 2.0 lays out without overflow', (tester) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester);

      expect(tester.takeException(), isNull);
      expect(copyButton(), findsOneWidget);
    });
  });
}
