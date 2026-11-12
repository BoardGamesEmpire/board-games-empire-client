import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/server_settings.dart';
import 'package:server_settings/src/widgets/mail_test_panel.dart';
import 'package:ui/ui.dart';

import 'support/harness.dart';

const _unsavedCopy =
    'Save your changes first: the test uses the saved settings.';
const _notConfiguredCopy = 'Save a host and a From address first.';

void main() {
  late int sends;

  setUp(() => sends = 0);

  Future<void> pumpPanel(
    WidgetTester tester, {
    MailTestState state = const MailTestIdle(),
    bool hasUnsavedChanges = false,
    bool mailConfigured = true,
    bool offline = false,
  }) async {
    await pumpOnPage(
      tester,
      MailTestPanel(
        state: state,
        hasUnsavedChanges: hasUnsavedChanges,
        mailConfigured: mailConfigured,
        onSend: () => sends++,
      ),
      offline: offline,
    );
    await tester.pumpAndSettle();
  }

  Finder send() => find.byKey(MailTestPanel.sendKey);

  FocusNode sendNode(WidgetTester tester) =>
      tester.widget<OutlinedButton>(send()).focusNode!;

  /// The button's one node, found by its name: the button's own widgets sit
  /// below it, outside the semantics tree.
  SemanticsNode sendSemantics(WidgetTester tester) =>
      tester.getSemantics(find.bySemanticsLabel('Send test email'));

  testWidgets('sends a test through the saved settings', (tester) async {
    await pumpPanel(tester);

    await tester.tap(send());
    await tester.pump();

    expect(sends, 1);
    expect(find.text(_unsavedCopy), findsNothing);
    expect(find.text(_notConfiguredCopy), findsNothing);
  });

  group('disabled, with its reason shown', () {
    testWidgets('while the group has unsaved changes', (tester) async {
      await pumpPanel(tester, hasUnsavedChanges: true);

      expect(tester.widget<OutlinedButton>(send()).onPressed, isNull);
      expect(find.text(_unsavedCopy), findsOneWidget);
      await tester.tap(send(), warnIfMissed: false);
      await tester.pump();
      expect(sends, 0);
    });

    testWidgets('while no host and From address are saved', (tester) async {
      await pumpPanel(tester, mailConfigured: false);

      expect(tester.widget<OutlinedButton>(send()).onPressed, isNull);
      expect(find.text(_notConfiguredCopy), findsOneWidget);
    });

    testWidgets('unsaved changes win over the missing settings: one reason', (
      tester,
    ) async {
      await pumpPanel(tester, hasUnsavedChanges: true, mailConfigured: false);

      expect(find.text(_unsavedCopy), findsOneWidget);
      expect(find.text(_notConfiguredCopy), findsNothing);
    });

    testWidgets('the reason reaches a screen reader with the button, read '
        'once', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPanel(tester, hasUnsavedChanges: true);

      final node = sendSemantics(tester);
      final data = node.getSemanticsData();
      expect(data.label, 'Send test email');
      expect(data.hint, _unsavedCopy);
      expect(node, isSemantics(hasEnabledState: true, isEnabled: false));
      // The drawn line is not a second node saying it again.
      expect(find.bySemanticsLabel(_unsavedCopy), findsNothing);
      handle.dispose();
    });

    testWidgets('offline, with the reason as its hint and no note of its own: '
        'the form draws the group its one note', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPanel(tester, offline: true);

      expect(tester.widget<OutlinedButton>(send()).onPressed, isNull);
      expect(sendSemantics(tester).getSemanticsData().hint, onlineOnlyCopy);
      expect(find.text(onlineOnlyCopy), findsNothing);
      handle.dispose();
    });
  });

  testWidgets('while a test is out it keeps focus and ignores a press', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPanel(tester);
    sendNode(tester).requestFocus();
    await tester.pump();

    await pumpPanel(tester, state: const MailTestWaiting(attempt: 1));
    await tester.tap(send());
    await tester.pump();

    expect(sends, 0);
    expect(FocusManager.instance.primaryFocus, same(sendNode(tester)));
    expect(
      sendSemantics(tester),
      isSemantics(hasEnabledState: true, isEnabled: false),
    );
    expect(
      find.text(
        "Test email queued for your address. Waiting for the mail server's "
        'answer…',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('while the request is being sent a press is ignored too', (
    tester,
  ) async {
    await pumpPanel(tester, state: const MailTestSending(attempt: 1));

    await tester.tap(send());
    await tester.pump();

    expect(sends, 0);
  });

  group('the outcome', () {
    MailTestOutcome failed(MailFailure failure, {String message = ''}) =>
        MailTestOutcome(
          attempt: 1,
          result: MailTestResult(
            sent: false,
            failure: failure,
            message: message,
          ),
        );

    testWidgets('a test that went says so', (tester) async {
      await pumpPanel(
        tester,
        state: const MailTestOutcome(
          attempt: 1,
          result: MailTestResult(sent: true, failure: null, message: 'ok'),
        ),
      );

      expect(
        find.text('The test email was sent. Check your inbox.'),
        findsOneWidget,
      );
      expect(find.text('ok'), findsNothing);
    });

    for (final (failure, copy) in [
      (MailFailure.notConfigured, "Mail isn't set up yet."),
      (
        MailFailure.settingsUnreadable,
        "The server couldn't read its mail settings. Save the password again.",
      ),
      (
        MailFailure.authFailed,
        'The mail server refused the user name or password.',
      ),
      (
        MailFailure.hostUnreachable,
        "Couldn't reach the mail server. Check the host and port.",
      ),
      (
        MailFailure.tlsFailed,
        'The secure connection to the mail server failed. Check the '
            "connection security and the server's certificate.",
      ),
      (
        MailFailure.rejected,
        'The mail server refused the message. Check the From address.',
      ),
      (MailFailure.sendFailed, "The mail server didn't take the message."),
    ]) {
      testWidgets('${failure.name} is told by its code, not the server '
          'message', (tester) async {
        await pumpPanel(
          tester,
          state: failed(failure, message: 'server words'),
        );

        expect(find.text(copy), findsOneWidget);
        expect(find.text('server words'), findsNothing);
      });
    }

    testWidgets('a code this app does not know shows the server message', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        state: failed(MailFailure.unknown, message: 'Greylisted, retry later'),
      );

      expect(find.text('Greylisted, retry later'), findsOneWidget);
    });

    for (final message in ['', '  \n ']) {
      testWidgets('a code this app does not know with no server message '
          '(${message.isEmpty ? 'empty' : 'blank'}) says the mail server did '
          'not take it', (tester) async {
        await pumpPanel(
          tester,
          state: failed(MailFailure.unknown, message: message),
        );

        expect(find.text('Test email failed'), findsOneWidget);
        expect(
          find.text("The mail server didn't take the message."),
          findsOneWidget,
        );
      });
    }

    testWidgets('an outcome that may answer an earlier test says so, after '
        'what it reports', (tester) async {
      await pumpPanel(
        tester,
        state: const MailTestOutcome(
          attempt: 2,
          result: MailTestResult(
            sent: false,
            failure: MailFailure.authFailed,
            message: 'm',
          ),
          mayAnswerEarlierTest: true,
        ),
      );

      expect(find.text('Test email failed'), findsOneWidget);
      expect(
        find.text(
          'The mail server refused the user name or password. An earlier '
          "test was still waiting for its answer, so this may be that one's. "
          'Send another test to be sure.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('no answer yet says to send another', (tester) async {
      await pumpPanel(tester, state: const MailTestNoResult(attempt: 1));

      expect(
        find.text(
          'No answer from the mail server yet. Send another test to try '
          'again.',
        ),
        findsOneWidget,
      );
    });

    for (final (reason, copy) in [
      (MailTestNotSentReason.notConfigured, _notConfiguredCopy),
      (
        MailTestNotSentReason.queueUnavailable,
        "The server's mail queue is down. Try again later.",
      ),
      (MailTestNotSentReason.refused, "Your role can't send a test email."),
      (
        MailTestNotSentReason.failed,
        "Couldn't send the test. Check your connection and try again.",
      ),
    ]) {
      testWidgets('a test not sent for ${reason.name} says why', (
        tester,
      ) async {
        await pumpPanel(
          tester,
          state: MailTestNotSent(attempt: 1, reason: reason),
        );

        expect(find.text(copy), findsOneWidget);
      });
    }

    testWidgets('nothing is said before a test, or while it is being sent', (
      tester,
    ) async {
      await pumpPanel(tester);
      expect(find.byType(BgeInlineBanner), findsNothing);

      await pumpPanel(tester, state: const MailTestSending(attempt: 1));
      expect(find.byType(BgeInlineBanner), findsNothing);
    });

    testWidgets('the same outcome on the next attempt is a new banner, so it '
        'is announced again', (tester) async {
      const result = MailTestResult(sent: true, failure: null, message: '');
      await pumpPanel(
        tester,
        state: const MailTestOutcome(attempt: 1, result: result),
      );
      final first = tester.state(find.byType(BgeInlineBanner));

      await pumpPanel(
        tester,
        state: const MailTestOutcome(attempt: 2, result: result),
      );

      expect(
        tester.widget(find.byType(BgeInlineBanner)).key,
        const ValueKey(2),
      );
      expect(tester.state(find.byType(BgeInlineBanner)), isNot(same(first)));
    });

    group('is titled when it says the test failed', () {
      String? title(WidgetTester tester) =>
          tester.widget<BgeInlineBanner>(find.byType(BgeInlineBanner)).title;

      testWidgets('not sent', (tester) async {
        await pumpPanel(
          tester,
          state: const MailTestNotSent(
            attempt: 1,
            reason: MailTestNotSentReason.notConfigured,
          ),
        );

        expect(title(tester), 'Test email not sent');
        expect(find.text('Test email not sent'), findsOneWidget);
      });

      testWidgets('failed', (tester) async {
        await pumpPanel(tester, state: failed(MailFailure.notConfigured));

        expect(title(tester), 'Test email failed');
        expect(find.text('Test email failed'), findsOneWidget);
      });

      for (final (name, state) in [
        (
          'sent',
          const MailTestOutcome(
            attempt: 1,
            result: MailTestResult(sent: true, failure: null, message: ''),
          ),
        ),
        ('waiting', const MailTestWaiting(attempt: 1)),
        ('no result', const MailTestNoResult(attempt: 1)),
      ]) {
        testWidgets('but not when $name', (tester) async {
          await pumpPanel(tester, state: state);

          expect(title(tester), isNull);
          expect(find.text('Test email not sent'), findsNothing);
          expect(find.text('Test email failed'), findsNothing);
        });
      }
    });

    testWidgets('the outcome is announced as it lands', (tester) async {
      await pumpPanel(tester, state: const MailTestNoResult(attempt: 1));

      expect(
        tester.widget<BgeInlineBanner>(find.byType(BgeInlineBanner)).announce,
        isTrue,
      );
    });
  });
}
