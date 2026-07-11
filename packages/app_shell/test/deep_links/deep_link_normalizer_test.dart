import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// `normalizeDeepLink` — validation of the published
/// `bge://server/{serverId}/{resource-path}[?...]` pattern and rewriting
/// into the path form declared by `reservedDeepLinkPathPatterns`.
void main() {
  group('normalizeDeepLink', () {
    group('accepts and rewrites', () {
      test('a minimal valid link to the declared path form', () {
        final result = normalizeDeepLink(
          Uri.parse('bge://server/abc123/game/42'),
        );

        expect(result, isA<DeepLinkNormalized>());
        final link = (result as DeepLinkNormalized).link;
        expect(link.serverId, 'abc123');
        expect(link.location, '/server/abc123/game/42');
      });

      test('a deep resource path, preserving every segment in order', () {
        final result = normalizeDeepLink(
          Uri.parse('bge://server/srv1/household/h9/invite/tok123'),
        );

        expect(result, isA<DeepLinkNormalized>());
        final link = (result as DeepLinkNormalized).link;
        expect(link.serverId, 'srv1');
        expect(link.location, '/server/srv1/household/h9/invite/tok123');
      });

      test('preserving the query string verbatim', () {
        final result = normalizeDeepLink(
          Uri.parse('bge://server/srv1/event/e7/rsvp/tok?source=email&x=1'),
        );

        expect(result, isA<DeepLinkNormalized>());
        expect(
          (result as DeepLinkNormalized).link.location,
          '/server/srv1/event/e7/rsvp/tok?source=email&x=1',
        );
      });

      test('dropping the fragment', () {
        final result = normalizeDeepLink(
          Uri.parse('bge://server/srv1/game/5#section'),
        );

        expect(result, isA<DeepLinkNormalized>());
        expect(
          (result as DeepLinkNormalized).link.location,
          '/server/srv1/game/5',
        );
      });

      test('uppercase scheme and host (Uri parsing lowercases both)', () {
        // RFC 3986: scheme and reg-name host are case-insensitive, and
        // Dart's Uri normalizes them during parsing — this pins that a
        // shouting link is not rejected on case grounds.
        final result = normalizeDeepLink(Uri.parse('BGE://SERVER/abc/game/1'));

        expect(result, isA<DeepLinkNormalized>());
        expect((result as DeepLinkNormalized).link.serverId, 'abc');
      });

      test('keeping a percent-encoded segment as a single segment', () {
        // An encoded slash inside a segment must not split it into two
        // path segments during the rewrite.
        final result = normalizeDeepLink(
          Uri.parse('bge://server/abc/game/a%2Fb'),
        );

        expect(result, isA<DeepLinkNormalized>());
        expect(
          (result as DeepLinkNormalized).link.location,
          '/server/abc/game/a%2Fb',
        );
      });
    });

    group('rejects', () {
      test('a non-bge scheme', () {
        final result = normalizeDeepLink(
          Uri.parse('https://server/abc/game/1'),
        );

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.unsupportedScheme,
        );
      });

      test('a lookalike scheme', () {
        final result = normalizeDeepLink(Uri.parse('bge2://server/abc/game/1'));

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.unsupportedScheme,
        );
      });

      test('an authority other than the literal `server`', () {
        final result = normalizeDeepLink(Uri.parse('bge://evil/abc/game/1'));

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.unexpectedAuthority,
        );
      });

      test('an authority carrying an explicit port', () {
        final result = normalizeDeepLink(
          Uri.parse('bge://server:8080/abc/game/1'),
        );

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.unexpectedAuthority,
        );
      });

      test('an authority carrying userInfo', () {
        final result = normalizeDeepLink(
          Uri.parse('bge://user@server/abc/game/1'),
        );

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.unexpectedAuthority,
        );
      });

      test('a link with no path at all', () {
        final result = normalizeDeepLink(Uri.parse('bge://server'));

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.missingServerId,
        );
      });

      test('an empty serverId segment', () {
        final result = normalizeDeepLink(Uri.parse('bge://server//game/1'));

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.missingServerId,
        );
      });

      test('a serverId with no resource path', () {
        final result = normalizeDeepLink(Uri.parse('bge://server/abc'));

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.missingResourcePath,
        );
      });

      test('a serverId with only a trailing slash for a resource path', () {
        final result = normalizeDeepLink(Uri.parse('bge://server/abc/'));

        expect(result, isA<DeepLinkRejected>());
        expect(
          (result as DeepLinkRejected).reason,
          DeepLinkRejectionReason.missingResourcePath,
        );
      });
    });
  });

  group('NormalizedDeepLink', () {
    test('value equality over serverId and location', () {
      const a = NormalizedDeepLink(
        serverId: 's1',
        location: '/server/s1/game/1',
      );
      const b = NormalizedDeepLink(
        serverId: 's1',
        location: '/server/s1/game/1',
      );
      const c = NormalizedDeepLink(
        serverId: 's1',
        location: '/server/s1/game/2',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('toString never leaks token segments', () {
      // toString escapes into logs, test-failure output, and crash
      // breadcrumbs — the invite token must not survive it.
      const link = NormalizedDeepLink(
        serverId: 's1',
        location: '/server/s1/household/h1/invite/SECRET-TOKEN',
      );

      final rendered = link.toString();

      expect(rendered, isNot(contains('SECRET-TOKEN')));
      expect(rendered, contains(deepLinkRedactionPlaceholder));
    });
  });
}
