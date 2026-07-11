import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// #10 red phase: `redactDeepLinkForLog` — invitation/RSVP tokens and
/// query values must never reach breadcrumbs (#34) or crash-report drafts
/// (#69). The output is a log-safe description, not a parseable URI.
void main() {
  group('redactDeepLinkForLog', () {
    test('redacts the segment following `invite`', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('/server/s1/household/h1/invite/SECRET-TOKEN'),
      );

      expect(rendered, '/server/s1/household/h1/invite/<redacted>');
    });

    test('redacts the segment following `rsvp`', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('/server/s1/event/e7/rsvp/SECRET-TOKEN'),
      );

      expect(rendered, '/server/s1/event/e7/rsvp/<redacted>');
    });

    test('redacts every query value while preserving keys', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('/server/s1/game/5?source=email&campaign=xyz'),
      );

      expect(
        rendered,
        '/server/s1/game/5?source=<redacted>&campaign=<redacted>',
      );
    });

    test('redacts a valueless query segment wholesale', () {
      // A bare segment has no key to preserve and could itself be a token,
      // so it must not be echoed as a "key" — this module is the leak-guard.
      final rendered = redactDeepLinkForLog(
        Uri.parse('/server/s1/game/5?SECRET-TOKEN'),
      );

      expect(rendered, '/server/s1/game/5?<redacted>');
      expect(rendered, isNot(contains('SECRET-TOKEN')));
    });

    test('redacts a fragment wholesale', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('/server/s1/game/5#SECRET'),
      );

      expect(rendered, '/server/s1/game/5#<redacted>');
      expect(rendered, isNot(contains('SECRET')));
    });

    test('leaves a token-free path untouched', () {
      final rendered = redactDeepLinkForLog(Uri.parse('/server/s1/game/42'));

      expect(rendered, '/server/s1/game/42');
    });

    test('handles the raw bge:// form, keeping scheme and authority', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://server/s1/event/e7/rsvp/SECRET?x=1'),
      );

      expect(rendered, 'bge://server/s1/event/e7/rsvp/<redacted>?x=<redacted>');
      expect(rendered, isNot(contains('SECRET')));
    });

    test('a trailing `invite` with nothing after it passes through', () {
      // Nothing to redact: the token segment is absent, and the marker
      // segment itself is not sensitive.
      final rendered = redactDeepLinkForLog(
        Uri.parse('/server/s1/household/h1/invite'),
      );

      expect(rendered, '/server/s1/household/h1/invite');
    });

    test('redacts multiple token markers independently', () {
      // Pathological but cheap to guarantee: every marker's follower is
      // redacted, not just the first.
      final rendered = redactDeepLinkForLog(
        Uri.parse('/x/invite/AAA/rsvp/BBB'),
      );

      expect(rendered, '/x/invite/<redacted>/rsvp/<redacted>');
    });

    test('uses the published placeholder constant', () {
      expect(deepLinkRedactionPlaceholder, '<redacted>');
    });
  });
}
