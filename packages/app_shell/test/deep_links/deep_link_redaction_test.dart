import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// #10 red phase: `redactDeepLinkForLog` — invitation/RSVP tokens and
/// query values must never reach breadcrumbs (#34) or crash-report drafts
/// (#69). The output is a log-safe description, not a parseable URI.
///
/// Extended by #178 with the credential cases: userInfo in the authority,
/// and the authority-less form where it hides in the path instead.
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

    test('redacts a userInfo component, keeping the marker', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://alice:hunter2@server/s1/game/5'),
      );

      expect(rendered, 'bge://<redacted>@server/s1/game/5');
      expect(rendered, isNot(contains('hunter2')));
    });

    test('redacts a passwordless userInfo component', () {
      // A bare username is still PII, and there is no key/value structure
      // here to preserve — unlike a query parameter, it goes wholesale.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://alice@server/s1/game/5'),
      );

      expect(rendered, 'bge://<redacted>@server/s1/game/5');
      expect(rendered, isNot(contains('alice')));
    });

    test('keeps an explicit port while redacting userInfo', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://alice:hunter2@server:8443/s1/game/5'),
      );

      expect(rendered, 'bge://<redacted>@server:8443/s1/game/5');
      expect(rendered, isNot(contains('hunter2')));
    });

    test('redacts userInfo and a path token together', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://alice:hunter2@server/s1/household/h1/invite/SECRET'),
      );

      expect(
        rendered,
        'bge://<redacted>@server/s1/household/h1/invite/<redacted>',
      );
      expect(rendered, isNot(contains('hunter2')));
      expect(rendered, isNot(contains('SECRET')));
    });

    test('a credential-free authority passes through with its port', () {
      // Pins the userInfo-free branch of the authority rewrite, so a
      // regression there cannot hide behind the credential cases.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://server:8443/s1/game/5'),
      );

      expect(rendered, 'bge://server:8443/s1/game/5');
    });

    test('redacts a credential smuggled into the host', () {
      // A reg-name may hold percent-escapes, so `alice%3Apw%40evil` is a
      // legal *host* — the authority is emitted as found, so it takes the
      // same delimiter rule as every other emitted component.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://alice%3Apw%40evil/s1/x'),
      );

      expect(rendered, 'bge://<redacted>@evil/s1/x');
      expect(rendered, isNot(contains('pw')));
    });

    test('a credential host keeps its port', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://alice%3Apw%40evil:8443/s1/x'),
      );

      expect(rendered, 'bge://<redacted>@evil:8443/s1/x');
      expect(rendered, isNot(contains('pw')));
    });

    test('userInfo and a credential host collapse to one marker', () {
      // The rule runs on the whole authority, so the last delimiter wins
      // and both the userInfo and the host prefix go in one pass.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://user:secret@alice%3Apw2%40evil/x'),
      );

      expect(rendered, 'bge://<redacted>@evil/x');
      expect(rendered, isNot(contains('secret')));
      expect(rendered, isNot(contains('pw2')));
    });

    test('keeps the brackets on an IPv6 host', () {
      // `Uri.host` drops the brackets and `Uri.authority` keeps them —
      // which is why the rewrite goes through the latter.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://[2001:db8::1]:8443/s1/game/5'),
      );

      expect(rendered, 'bge://[2001:db8::1]:8443/s1/game/5');
    });

    test(
      'redacts credentials hiding in the path when there is no authority',
      () {
        // `bge:` with no `//` gives Uri nothing to parse as userInfo, so the
        // credential arrives as ordinary path text (#178). Rendering it with
        // a fabricated `//` used to disguise the leak as a redacted link.
        final rendered = redactDeepLinkForLog(
          Uri.parse('bge:alice:hunter2@server/s1/game/5'),
        );

        expect(rendered, 'bge:<redacted>@server/s1/game/5');
        expect(rendered, isNot(contains('hunter2')));
      },
    );

    test('does not fabricate an authority for a scheme-only link', () {
      final rendered = redactDeepLinkForLog(Uri.parse('bge:foo'));

      expect(rendered, 'bge:foo');
    });

    test('a percent-encoded `@` cannot dodge the credential check', () {
      // `@` is a legal pchar, so `Uri` leaves `%40` encoded in the path.
      // The delimiter is matched raw in both spellings rather than decoded
      // — only the invite/rsvp markers decode — so that an unrelated bad
      // escape in the same segment cannot hide it (see below).
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge:alice:hunter2%40server/s1/game/5'),
      );

      expect(rendered, 'bge:<redacted>@server/s1/game/5');
      expect(rendered, isNot(contains('hunter2')));
    });

    test('redacts a credential-shaped segment even when a host exists', () {
      // This link passes every normalizer check — host `server`, no
      // userInfo, serverId and resource path present — so it is logged on
      // the ACCEPT path at info, not just echoed back at a rejected
      // attacker. The delimiter rule applies to every emitted component.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://server/alice:hunter2@evil/game/5'),
      );

      expect(rendered, 'bge://server/<redacted>@evil/game/5');
      expect(rendered, isNot(contains('hunter2')));
    });

    test('an email-shaped segment keeps its domain', () {
      // Same shape `Redaction.redactEmail` produces downstream: local
      // part masked, domain kept — so the segment rule costs nothing the
      // repo-wide email convention was not already going to take.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://server/s1/user@example.com/game/5'),
      );

      expect(rendered, 'bge://server/s1/<redacted>@example.com/game/5');
    });

    test('redacts a credential-shaped query key', () {
      // Keys are normally preserved for shape — but a key is emitted as
      // found, so the same delimiter rule runs on it first. No legitimate
      // key contains `@`; one that does is doing a credential's job.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://evil/x?alice:hunter2%40server=value'),
      );

      expect(rendered, 'bge://evil/x?<redacted>@server=<redacted>');
      expect(rendered, isNot(contains('hunter2')));
    });

    test('redacts credentials in the path of a triple-slash link', () {
      // `bge:///…` parses with an authority that is *present but empty*, so
      // `Uri` still had nothing to lift a userInfo into and the credential
      // stays in the path. `hasAuthority` alone would wave this through.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge:///alice:hunter2@server/s1/game/5'),
      );

      expect(rendered, 'bge:///<redacted>@server/s1/game/5');
      expect(rendered, isNot(contains('hunter2')));
    });

    test('redacts credentials in the path of a hostless authority', () {
      // Same hole one step along: an authority carrying only a port has no
      // host either, so the leading path text is still doing an
      // authority's job.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://:8443/alice:hunter2@server/x'),
      );

      expect(rendered, 'bge://:8443/<redacted>@server/x');
      expect(rendered, isNot(contains('hunter2')));
    });

    test('an encoded control character cannot forge a log line', () {
      // The suffix is emitted raw. Decoding it first would turn `%0A` into
      // a real newline inside the breadcrumb, letting a hostile link forge
      // a second log entry in the feedback report.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge:user:pw%40server%0Aforged/s1/game/5'),
      );

      expect(rendered, 'bge:<redacted>@server%0Aforged/s1/game/5');
      expect(rendered, isNot(contains('\n')));
    });

    test('an unrelated bad escape does not disarm the delimiter', () {
      // `%FF` makes the segment undecodable, so a decode-then-match scheme
      // falls back to raw text and misses the `%40` — leaking the very
      // credential it is looking for. The delimiter is matched raw.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge:user:pw%40server%FF/s1/game/5'),
      );

      expect(rendered, 'bge:<redacted>@server%FF/s1/game/5');
      expect(rendered, isNot(contains('pw')));
    });

    test('the last delimiter wins across both spellings', () {
      final rendered = redactDeepLinkForLog(Uri.parse('bge:a%40b@c/s1'));

      expect(rendered, 'bge:<redacted>@c/s1');
    });

    test('an undecodable percent-escape renders instead of throwing', () {
      // `%FF` is not valid UTF-8 and `Uri.decodeComponent` throws on it.
      // That throw would escape `DeepLinkHandler._onUri` past both log
      // calls, so a hostile link would leave no breadcrumb at all.
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://server/%FF/game/5'),
      );

      expect(rendered, 'bge://server/%FF/game/5');
    });

    test('an undecodable escape does not disarm the token markers', () {
      final rendered = redactDeepLinkForLog(
        Uri.parse('bge://server/%FF/invite/SECRET'),
      );

      expect(rendered, 'bge://server/%FF/invite/<redacted>');
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

    test('no hostile spelling of one secret survives any component', () {
      // The completeness claim, as a test rather than a doc paragraph: the
      // same secret pushed through every component that can carry it, in
      // every spelling. Each round of review on #178 found one more of
      // these; a new one belongs here first.
      const secret = 'hunter2';
      final hostile = <String>[
        'bge://alice:$secret@server/s1/game/5', // userInfo
        'bge:alice:$secret@server/s1/game/5', // no authority
        'bge:///alice:$secret@server/s1/game/5', // empty authority
        'bge://:8443/alice:$secret@server/x', // hostless authority
        'bge://alice%3A$secret%40evil/s1/x', // inside the host
        'bge://server/alice:$secret@evil/game/5', // accepted link
        'bge://server/s1/user:$secret@h/game/5', // mid-path
        'bge:alice:$secret%40server/s1/game/5', // encoded delimiter
        'bge:alice:$secret%40server%FF/s1/game/5', // bad escape alongside
        'bge:alice:$secret%40server%0Aforged/s1/x', // control character
        'bge://evil/x?alice:$secret%40server=value', // query key
        'bge://server/s1/game/5?token=$secret', // query value
        'bge://server/s1/game/5#$secret', // fragment
        'bge://server/s1/household/h1/invite/$secret', // token marker
      ];

      for (final raw in hostile) {
        final rendered = redactDeepLinkForLog(Uri.parse(raw));

        expect(rendered, isNot(contains(secret)), reason: 'leaked from $raw');
        expect(
          rendered,
          isNot(contains('\n')),
          reason: 'forged a log line from $raw',
        );
      }
    });
  });
}
