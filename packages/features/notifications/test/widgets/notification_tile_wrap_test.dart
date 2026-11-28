import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifications/l10n/notifications_localizations_en.dart';
import 'package:notifications/notifications.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A notification row on the smallest phone at the largest text (#475).
///
/// A file of its own because it loads the display typeface, which then draws
/// every title in the file.
void main() {
  setUpAll(loadDisplayFont);

  final l10n = NotificationsLocalizationsEn();
  final title = l10n.notificationHouseholdInviteReceivedTitle(
    'Ana',
    'The Extraordinarily Long-Named Household of Saturday Night '
        'Boardgamers-and-Friends-of-Friends-Unlimited',
  );

  for (final (name, presentation) in [
    (
      'a row that opens',
      NotificationPresentation(
        icon: Icons.mail_outline,
        title: title,
        detail: l10n.notificationInviteeDetail('Bo'),
        quote:
            'getaddrinfo ENOTFOUND '
            'gateway.boardgames-extraordinarily-long-hostname.example',
        target: const InviteInboxTarget(),
      ),
    ),
    (
      'a plain row',
      NotificationPresentation(icon: Icons.notifications_none, title: title),
    ),
  ]) {
    testWidgets('$name: a long household name wraps at 320dp and 2.0 text '
        'without overflow', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              NotificationsLocalizations.localizationsDelegates,
          supportedLocales: NotificationsLocalizations.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: [
                NotificationTile(
                  presentation: presentation,
                  read: false,
                  createdAt: DateTime.utc(2026, 11, 27, 15, 4),
                  onOpen: () {},
                  onMarkRead: () {},
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.text(title)),
        ).scale(10),
        20,
        reason: 'the row is drawn at 2.0 text',
      );

      final paragraph = tester.renderObject<RenderParagraph>(find.text(title));
      // Wrapped, not cut: every line laid out, every glyph inside the row.
      expect(paragraph.didExceedMaxLines, isFalse);
      final screen = Offset.zero & const Size(320, 640);
      final rect = tester.getRect(find.text(title));
      expect(rect.left, greaterThanOrEqualTo(screen.left));
      expect(rect.right, lessThanOrEqualTo(screen.right));
      expect(
        paragraph.getMaxIntrinsicWidth(double.infinity),
        greaterThan(paragraph.size.width),
        reason: 'the name is longer than a line, so it has to wrap',
      );
      // And it did: its glyphs sit on more than one line, every one inside
      // the title's box. One line cut at the edge would have one top. The
      // space a line breaks at may hang past the edge, so only the glyphs
      // that draw are measured.
      final text = paragraph.text.toPlainText();
      final glyphs = [
        for (var i = 0; i < text.length; i++)
          if (text[i].trim().isNotEmpty)
            ...paragraph.getBoxesForSelection(
              TextSelection(baseOffset: i, extentOffset: i + 1),
            ),
      ];
      expect(
        {for (final box in glyphs) box.top}.length,
        greaterThan(1),
        reason: 'the title is drawn on more than one line',
      );
      for (final box in glyphs) {
        expect(
          box.right,
          lessThanOrEqualTo(paragraph.size.width + 0.01),
          reason: 'a glyph is drawn past the edge',
        );
      }

      // Every line of the row, the quote's and the button's included.
      final lines = find.descendant(
        of: find.byType(NotificationTile),
        matching: find.byType(RichText),
      );
      expect(lines, findsAtLeastNWidgets(3));
      for (final element in lines.evaluate()) {
        final box = element.renderObject! as RenderParagraph;
        final words = box.text.toPlainText();
        expect(box.didExceedMaxLines, isFalse, reason: '"$words" is cut');
        expect(
          box.localToGlobal(box.size.bottomRight(Offset.zero)).dx,
          lessThanOrEqualTo(320),
          reason: '"$words" runs off the screen',
        );
      }
    });
  }
}
