import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

void main() {
  const secret = 'bge_s3cr3t_a1B2c3D4e5F6';
  const once =
      'This is the only time the key is shown. Copy it now and store it '
      'somewhere safe.';

  CreatedApiKey made({String? name = 'CI deploy'}) => CreatedApiKey(
    apiKey: apiKey('k_new', name: name),
    secret: secret,
  );

  /// How many times Done was pressed.
  late int done;

  setUp(() => done = 0);

  Future<void> pump(
    WidgetTester tester, {
    CreatedApiKey? created,
    bool announce = true,
  }) => pumpOnPage(
    tester,
    SecretPanel(
      created: created ?? made(),
      onDone: () => done++,
      announce: announce,
    ),
  );

  Finder copyButton() => find.byKey(SecretPanel.copyKey);

  FocusNode copyFocus(WidgetTester tester) => Focus.of(
    tester.element(
      find.descendant(of: copyButton(), matching: find.text('Copy key')),
    ),
  );

  group('SecretPanel', () {
    testWidgets("shows the key's name, the secret as selectable text, Copy, "
        'the warning and Done', (tester) async {
      await pump(tester);

      expect(find.text('CI deploy'), findsOneWidget);
      expect(find.text('Your new key'), findsOneWidget);
      final shown = tester.widget<SelectableText>(
        find.byKey(SecretPanel.secretKey),
      );
      expect(shown.data, secret);
      expect(shown.style?.fontFamily, BgeTypography.monospaceFamily);
      expect(find.text('Copy key'), findsOneWidget);
      expect(find.text(once), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(SecretPanel.doneKey)).child,
        isA<Text>().having((text) => text.data, 'label', 'Done'),
      );
    });

    testWidgets('the secret is drawn once, and nowhere else', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      // The one editable that holds it: no label, hint or tooltip repeats it.
      expect(find.text(secret), findsOneWidget);
      final carrying = find.semantics
          .byPredicate((node) {
            final data = node.getSemanticsData();
            return [
              data.label,
              data.value,
              data.hint,
              data.tooltip,
            ].any((words) => words.contains(secret));
          })
          .evaluate()
          .map((node) => node.getSemanticsData())
          .toList();
      expect(carrying, hasLength(1));
      expect(carrying.single.value, secret);
      expect(carrying.single.label, isNot(contains(secret)));
      expect(carrying.single.hint, isNot(contains(secret)));
      expect(carrying.single.tooltip, isNot(contains(secret)));
      semantics.dispose();
    });

    testWidgets('an unnamed key is called what its row calls it', (
      tester,
    ) async {
      await pump(tester, created: made(name: null));

      expect(find.text('Unnamed key'), findsOneWidget);
    });

    testWidgets('the name is a heading, and the warning is said as it '
        'arrives', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      expect(
        tester.getSemantics(find.text('CI deploy')).flagsCollection.isHeader,
        isTrue,
      );
      final banner = tester.widget<BgeInlineBanner>(
        find.byKey(SecretPanel.noticeKey),
      );
      expect(banner.tone, BgeBannerTone.warning);
      expect(banner.announce, isTrue);
      // It stays where it is drawn: the panel's top is what shows first.
      expect(banner.reveal, isFalse);
      semantics.dispose();
    });

    testWidgets('announce false keeps the warning from being said again', (
      tester,
    ) async {
      await pump(tester, announce: false);

      expect(
        tester
            .widget<BgeInlineBanner>(find.byKey(SecretPanel.noticeKey))
            .announce,
        isFalse,
      );
    });

    testWidgets('Copy puts the secret on the clipboard and says Key copied', (
      tester,
    ) async {
      final copies = captureClipboardCopies();
      await pump(tester);

      await tester.tap(copyButton());
      await tester.pumpAndSettle();

      expect(copies, [secret]);
      expect(find.text('Key copied'), findsOneWidget);
      // Said in words that never hold the key.
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining(secret),
        ),
        findsNothing,
      );
      expect(done, 0);
    });

    testWidgets('Copy keeps focus through the copy, and a second press '
        'leaves one bar', (tester) async {
      final copies = captureClipboardCopies();
      await pump(tester);

      copyFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(copyFocus(tester).hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(copies, [secret, secret]);
      expect(find.text('Key copied'), findsOneWidget);
      expect(copyFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('a copy that fails says so, and how to copy it anyway', (
      tester,
    ) async {
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
      await pump(tester);

      await tester.tap(copyButton());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.text("Couldn't copy the key. Select it and copy it yourself."),
        findsOneWidget,
      );
      expect(find.text('Key copied'), findsNothing);
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

      expect(
        find.text("Couldn't copy the key. Select it and copy it yourself."),
        findsOneWidget,
      );
      expect(find.text('Key copied'), findsNothing);
    });

    testWidgets('Done calls onDone', (tester) async {
      await pump(tester);

      await tester.ensureVisible(find.byKey(SecretPanel.doneKey));
      await tester.tap(find.byKey(SecretPanel.doneKey));
      await tester.pump();

      expect(done, 1);
    });

    testWidgets('320dp at 2.0 lays out a long secret without overflow', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pump(
        tester,
        created: CreatedApiKey(
          apiKey: apiKey('k_new', name: 'A rather long name of 32 chars!!'),
          secret: 'bge_${'a1B2c3D4' * 8}',
        ),
      );

      expect(tester.takeException(), isNull);
      // The whole secret is laid out inside the page, not cut off beside it.
      final shown = tester.getRect(find.byKey(SecretPanel.secretKey));
      expect(shown.left, greaterThanOrEqualTo(0));
      expect(shown.right, lessThanOrEqualTo(320));
    });
  });
}
